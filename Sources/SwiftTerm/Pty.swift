//
//  File.swift
//  
//
//  Created by Miguel de Icaza on 3/4/20.
//

#if !SWIFTTERM_EMBEDDED
import Foundation
#if !os(WASI) && !os(iOS) && !os(tvOS) && !os(Windows)

/**
 * APIs to assist in controlling a Unix pseudo-terminal from Swift.
 *
 *This provides a wrapper for
 * the libc `forkpty`API in the form of `fork(andExec:args:env:desiredWindowSize:` method,
 * `setWinSize` and `availableBytes`
 */
public class PseudoTerminalHelpers {
    private struct CStringArray {
        let base: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
        let count: Int
    }

    private static func allocateCStringArray(_ strings: [String]) -> CStringArray? {
        let base = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        var initializedCount = 0

        for (index, string) in strings.enumerated() {
            guard let duplicated = strdup(string) else {
                for cleanupIndex in 0..<initializedCount {
                    free(base[cleanupIndex])
                }
                base.deallocate()
                return nil
            }
            base[index] = duplicated
            initializedCount += 1
        }

        base[strings.count] = nil
        return CStringArray(base: base, count: strings.count)
    }

    private static func freeCStringArray(_ array: CStringArray) {
        for index in 0..<array.count {
            free(array.base[index])
        }
        array.base.deallocate()
    }

    /**
     * This method both forks and executes the provided command under a Pseudo Terminal (pty)
     * - Parameter andExec: the name of the executable to run
     * - Parameter args: arguments to be passed to the executable
     * - Parameter env: the environment variables for the child process
     * - Parameter desiredWindowSize: the window size that will be set on the pseudo terminal.
     *
     * - Returns: nil on error, or a tuple containing the process ID, and the file descriptor to the primary side of the newly created pseudo-terminal.
     */
    public static func fork (andExec: String, args: [String], env: [String], currentDirectory: String? = nil, desiredWindowSize: inout winsize) -> (pid: pid_t, masterFd: Int32)?
    {
        guard let cArgs = allocateCStringArray(args) else {
            return nil
        }
        guard let cEnv = allocateCStringArray(env) else {
            freeCStringArray(cArgs)
            return nil
        }
        guard let cExecutable = strdup(andExec) else {
            freeCStringArray(cEnv)
            freeCStringArray(cArgs)
            return nil
        }

        var cCurrentDirectory: UnsafeMutablePointer<CChar>?
        if let currentDirectory {
            guard let duplicatedCurrentDirectory = strdup(currentDirectory) else {
                free(cExecutable)
                freeCStringArray(cEnv)
                freeCStringArray(cArgs)
                return nil
            }
            cCurrentDirectory = duplicatedCurrentDirectory
        }

        defer {
            freeCStringArray(cArgs)
            freeCStringArray(cEnv)
            free(cExecutable)
            if let cCurrentDirectory {
                free(cCurrentDirectory)
            }
        }

        // Worked out before fork, like the signal state below: the child
        // closes every descriptor from 3 up to this before execve, so the
        // program starts with its terminal and nothing else of the host's.
        let descriptorBound = inheritedDescriptorBound()

        // Build the signal state before fork. The child must use only
        // async-signal-safe system calls until execve.
        var defaultAction = sigaction()
#if canImport(Darwin)
        defaultAction.__sigaction_u.__sa_handler = SIG_DFL
#elseif canImport(Musl)
        defaultAction.__sa_handler.sa_handler = SIG_DFL
#else
        defaultAction.__sigaction_handler.sa_handler = SIG_DFL
#endif
        sigemptyset(&defaultAction.sa_mask)
        defaultAction.sa_flags = 0
        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        var master: Int32 = 0

        let pid = forkpty(&master, nil, nil, &desiredWindowSize)
        if pid < 0 {
            return nil
        }
        if pid == 0 {
            // Signal ignores and the calling thread's mask survive exec.
            // A server can ignore SIGINT for a DispatchSource or block it on
            // a worker thread. Do not pass that policy to terminal programs.
            // Reset dispositions before unblocking, so no inherited handler
            // can run in the child between fork and exec. Some platforms
            // reserve signal numbers; sigaction rejects those with EINVAL.
            var number: Int32 = 1
            while number < NSIG {
                if number != SIGKILL && number != SIGSTOP {
                    _ = sigaction(number, &defaultAction, nil)
                }
                number += 1
            }
            if sigprocmask(SIG_SETMASK, &emptyMask, nil) != 0 {
                _exit(127)
            }
            if let cCurrentDirectory {
                _ = chdir(cCurrentDirectory)
            }
            // A descriptor the host opened without close-on-exec would
            // otherwise reach the program: a pipe the host is reading (the
            // program could consume its data), or one it is writing (the
            // host never sees end-of-file while the program lives). forkpty
            // has made 0, 1 and 2 the terminal; close(2) is
            // async-signal-safe and the loop allocates nothing.
            var descriptor: Int32 = 3
            while descriptor < descriptorBound {
                _ = close(descriptor)
                descriptor += 1
            }

            _ = execve(cExecutable, cArgs.base, cEnv.base)
            _exit(127)
        }
        return (pid, master)
    }
    
    /// One past the highest descriptor the child might have inherited: the
    /// soft descriptor limit, capped so an unlimited limit does not mean
    /// billions of close calls, and never below the highest descriptor open
    /// now (with room for any another thread opens before the fork).
    static func inheritedDescriptorBound() -> Int32 {
        let cap: Int64 = 65_536
        var limit = rlimit()
        var bound: Int64 = 1_024
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 {
            // An unlimited limit is the largest rlim_t, which the cap takes care of.
            bound = min(Int64(clamping: limit.rlim_cur), cap)
        }
#if os(macOS)
        let stride = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        if bytes > 0 {
            var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 64)
            let filled = entries.withUnsafeMutableBytes { buffer in
                proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            if let highest = entries.prefix(Int(max(filled, 0)) / stride).map({ Int64($0.proc_fd) }).max() {
                bound = max(bound, highest + 256)
            }
        }
#endif
        return Int32(clamping: bound)
    }

    /**
     * Sets the window size of the underlying pseudo terminal.
     * - Parameter masterPtyDescriptor: a pseudo-terminal master file descriptor, as returned by fork(andExec:)
     * - Returns: the value from calling the ioctl
     */
    public static func setWinSize (masterPtyDescriptor: Int32, windowSize: inout winsize) -> Int32
    {
#if os(macOS)
        return ioctl(masterPtyDescriptor, TIOCSWINSZ, &windowSize)
#else
	return ioctl(masterPtyDescriptor, UInt(TIOCSWINSZ), &windowSize)
#endif
    }
    
    /**
     * Returns the number of available bytes to be read from the file descriptor
     */
    public static func availableBytes (fd: Int32) -> (status: Int32, size: Int32)
    {
        var size: Int32 = 0
        let status = ioctl (fd, 0x4004667f /* FIONREAD */, &size)
        return (status, size)
    }

    /// Reads the enabled `termios.c_cc` bytes from a PTY.
    ///
    /// The result contains only C0 and DEL values. A disabled entry, NUL, and
    /// values outside that range are not returned. The caller must use the
    /// approximation when this method returns `nil`.
    public static func terminalControlBytesForPaste(
        masterPtyDescriptor: Int32
    ) -> Set<UInt8>? {
        guard masterPtyDescriptor >= 0 else { return nil }

        var attributes = termios()
        guard tcgetattr(masterPtyDescriptor, &attributes) == 0 else { return nil }

        var indices: [Int32] = [
            VEOF, VEOL, VERASE, VINTR, VKILL, VQUIT, VSTART, VSTOP, VSUSP,
        ]
#if os(macOS)
        indices += [VDISCARD, VDSUSP, VEOL2, VLNEXT, VREPRINT, VSTATUS, VWERASE]
#elseif os(Linux)
        indices += [VDISCARD, VEOL2, VLNEXT, VREPRINT, VSWTC, VWERASE]
#endif

        let disabledValue = fpathconf(masterPtyDescriptor, Int32(_PC_VDISABLE))
        let disabledByte: UInt8? = disabledValue >= 0 && disabledValue <= 0xff
            ? UInt8(disabledValue)
            : nil
        let controlCharacters = withUnsafeBytes(of: &attributes.c_cc) { Array($0) }

        var result: Set<UInt8> = []
        for indexValue in indices {
            let index = Int(indexValue)
            guard controlCharacters.indices.contains(index) else { continue }
            let byte = controlCharacters[index]
            guard byte != 0 else { continue }
            if let disabledByte, byte == disabledByte { continue }
            guard byte < 0x20 || byte == 0x7f else { continue }
            result.insert(byte)
        }
        return result
    }
}
#endif

#endif // !SWIFTTERM_EMBEDDED
