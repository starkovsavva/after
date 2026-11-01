#!/usr/bin/env python3
"""macOS-only ad-hoc signed XPC reachability/peer-requirement research probe.

Builds a disposable app and XPC service in /private/tmp. It observes whether
a direct call with a wrong cdhash reaches the service, then checks a harmless
handshake and an anonymous capability channel after service exit. No
installation, user files, network or embedding model are involved. A pass does
not establish production packaging, lifecycle or full IPC security.
"""
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import uuid


SERVICE = r'''
import Foundation

@objc(AfterXPCProbeProtocol) protocol AfterXPCProbeProtocol {
    func echo(_ value: String, withReply reply: @escaping (String) -> Void)
    func capability(withReply reply: @escaping (NSXPCListenerEndpoint) -> Void)
}
final class Endpoint: NSObject, AfterXPCProbeProtocol {
    var listener: NSXPCListener!
    func echo(_ value: String, withReply reply: @escaping (String) -> Void) {
        if value == "mismatch-canary" || value == "after-death-canary" {
            try? Data("received".utf8).write(to: URL(fileURLWithPath: "MARKER_PATH"))
        }
        reply(value)
        if value == "stop-service" {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) { exit(0) }
        }
    }
    func capability(withReply reply: @escaping (NSXPCListenerEndpoint) -> Void) { reply(listener.endpoint) }
}
final class Delegate: NSObject, NSXPCListenerDelegate {
    let endpoint = Endpoint()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AfterXPCProbeProtocol.self)
        connection.exportedObject = endpoint
        connection.resume()
        return true
    }
}
let delegate = Delegate()
let anonymous = NSXPCListener.anonymous()
anonymous.delegate = delegate
delegate.endpoint.listener = anonymous
anonymous.resume()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
withExtendedLifetime(delegate) { RunLoop.current.run() }
'''

HOST = r'''
import Foundation

@objc(AfterXPCProbeProtocol) protocol AfterXPCProbeProtocol {
    func echo(_ value: String, withReply reply: @escaping (String) -> Void)
    func capability(withReply reply: @escaping (NSXPCListenerEndpoint) -> Void)
}
func probe(_ requirement: String, expectReply: Bool) -> Bool {
    let connection = NSXPCConnection(serviceName: "SERVICE_ID")
    connection.remoteObjectInterface = NSXPCInterface(with: AfterXPCProbeProtocol.self)
    connection.setCodeSigningRequirement(requirement)
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var replied = false
    connection.invalidationHandler = { done.signal() }
    connection.resume()
    let object = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! AfterXPCProbeProtocol
    let message = expectReply ? "synthetic" : "mismatch-canary"
    object.echo(message) { value in
        lock.lock(); replied = value == message; lock.unlock(); done.signal()
    }
    let result = done.wait(timeout: .now() + 12)
    lock.lock(); let received = replied; lock.unlock()
    connection.invalidate()
    return result == .success && received == expectReply
}
guard probe("cdhash H\"SERVICE_HASH\"", expectReply: true) else {
    fputs("trusted service failed\n", stderr); exit(1)
}
let directRejected = probe("cdhash H\"0000000000000000000000000000000000000000\"", expectReply: false)
Thread.sleep(forTimeInterval: 1)
let directDelivered = FileManager.default.fileExists(atPath: "MARKER_PATH")
print("OBSERVED: direct call rejected=\(directRejected), payload delivered=\(directDelivered)")
try? FileManager.default.removeItem(atPath: "MARKER_PATH")
func negotiate(_ requirement: String) -> (NSXPCConnection, NSXPCListenerEndpoint)? {
    let connection = NSXPCConnection(serviceName: "SERVICE_ID")
    connection.remoteObjectInterface = NSXPCInterface(with: AfterXPCProbeProtocol.self)
    connection.setCodeSigningRequirement(requirement)
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var endpoint: NSXPCListenerEndpoint?
    connection.invalidationHandler = { done.signal() }
    connection.resume()
    let object = connection.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! AfterXPCProbeProtocol
    object.capability { value in lock.lock(); endpoint = value; lock.unlock(); done.signal() }
    _ = done.wait(timeout: .now() + 12)
    lock.lock(); let value = endpoint; lock.unlock()
    guard let value else { connection.invalidate(); return nil }
    return (connection, value)
}
guard negotiate("cdhash H\"0000000000000000000000000000000000000000\"") == nil else {
    fputs("mismatched service returned a capability\n", stderr); exit(1)
}
guard let (bootstrap, endpoint) = negotiate("cdhash H\"SERVICE_HASH\"") else {
    fputs("trusted capability handshake failed\n", stderr); exit(1)
}
let channel = NSXPCConnection(listenerEndpoint: endpoint)
channel.remoteObjectInterface = NSXPCInterface(with: AfterXPCProbeProtocol.self)
channel.setCodeSigningRequirement("cdhash H\"SERVICE_HASH\"")
channel.resume()
func exchange(_ text: String) -> Bool {
    let done = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var matched = false
    let object = channel.remoteObjectProxyWithErrorHandler { _ in done.signal() } as! AfterXPCProbeProtocol
    object.echo(text) { value in lock.lock(); matched = value == text; lock.unlock(); done.signal() }
    _ = done.wait(timeout: .now() + 12)
    lock.lock(); let result = matched; lock.unlock()
    return result
}
guard exchange("synthetic") && exchange("stop-service") else {
    fputs("authenticated endpoint failed\n", stderr); exit(1)
}
Thread.sleep(forTimeInterval: 1)
guard !exchange("after-death-canary") else {
    fputs("endpoint unexpectedly reconnected after service exit\n", stderr); exit(1)
}
Thread.sleep(forTimeInterval: 1)
guard !FileManager.default.fileExists(atPath: "MARKER_PATH") else {
    fputs("payload reached restarted service\n", stderr); exit(1)
}
channel.invalidate(); bootstrap.invalidate()
print("PASS: authenticated anonymous endpoint did not reconnect after process exit")
'''


def run(command, *, environment, timeout=90):
    return subprocess.run(command, check=True, env=environment, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True, timeout=timeout)


def main():
    with tempfile.TemporaryDirectory(prefix="after-xpc-probe-", dir="/private/tmp") as name:
        root = Path(name).resolve()
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(root),
                       "SWIFT_MODULECACHE_PATH": str(root / "swift-cache"),
                       "CLANG_MODULE_CACHE_PATH": str(root / "clang-cache")}
        service_id = "dev.after.xpcprobe.s" + uuid.uuid4().hex
        app = root / "Probe.app"
        xpc = app / "Contents/XPCServices/Probe.xpc"
        app_bin = app / "Contents/MacOS/Probe"
        xpc_bin = xpc / "Contents/MacOS/ProbeService"
        app_bin.parent.mkdir(parents=True)
        xpc_bin.parent.mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.after.xpcprobe.host", "CFBundleExecutable": "Probe",
            "CFBundlePackageType": "APPL", "CFBundleName": "Probe", "CFBundleVersion": "1"}))
        (xpc / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": service_id, "CFBundleExecutable": "ProbeService",
            "CFBundlePackageType": "XPC!", "CFBundleVersion": "1",
            "XPCService": {"ServiceType": "Application", "RunLoopType": "NSRunLoop"}}))
        service_source = root / "service.swift"
        marker_path = str(root / "mismatch-received")
        service_source.write_text(SERVICE.replace("MARKER_PATH", marker_path))
        run(["/usr/bin/xcrun", "swiftc", str(service_source), "-o", str(xpc_bin)], environment=environment)
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(xpc)], environment=environment)
        details = run(["/usr/bin/codesign", "-dv", "--verbose=4", str(xpc)], environment=environment)
        match = re.search(r"(?m)^CDHash=([0-9a-f]{40})$", details.stderr)
        if not match:
            raise RuntimeError("could not inspect temporary service signature")
        host_source = root / "host.swift"
        host_source.write_text(HOST.replace("SERVICE_ID", service_id).replace("SERVICE_HASH", match.group(1)).replace("MARKER_PATH", marker_path))
        run(["/usr/bin/xcrun", "swiftc", str(host_source), "-o", str(app_bin)], environment=environment)
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], environment=environment)
        result = subprocess.run([str(app_bin)], env=environment, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True, timeout=30)
        if result.returncode:
            raise RuntimeError("XPC probe failed: " + result.stderr.strip())
        print(result.stdout.strip())


if __name__ == "__main__":
    main()
