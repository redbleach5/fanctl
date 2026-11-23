// gpuburn.swift — нагрузка GPU через Metal compute (для корреляции датчиков)
// swiftc gpuburn.swift -o gpuburn -framework Metal -framework Foundation
import Foundation
import Metal

let seconds = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 15.0 : 15.0

guard let device = MTLCreateSystemDefaultDevice() else { fatalError("no Metal device") }
guard let queue = device.makeCommandQueue() else { fatalError("no queue") }

let source = """
#include <metal_stdlib>
using namespace metal;
kernel void burn(device float *buf [[buffer(0)]], uint id [[thread_position_in_grid]]) {
    float x = buf[id];
    for (int i = 0; i < 4096; i++) { x = fma(x, 1.000001f, 0.000001f); }
    buf[id] = x;
}
"""

let library: MTLLibrary
do { library = try device.makeLibrary(source: source, options: nil) }
catch { fatalError("compile failed: \(error)") }
guard let function = library.makeFunction(name: "burn"),
      let pso = try? device.makeComputePipelineState(function: function)
else { fatalError("pipeline failed") }

let n = 1 << 20
guard let buf = device.makeBuffer(length: n * MemoryLayout<Float>.size, options: .storageModeShared)
else { fatalError("buffer failed") }

print("GPU burn for \(seconds)s on \(device.name)")
let start = Date()
var iters = 0
while Date().timeIntervalSince(start) < seconds {
    guard let cb = queue.makeCommandBuffer(),
          let enc = cb.makeComputeCommandEncoder() else { break }
    enc.setComputePipelineState(pso)
    enc.setBuffer(buf, offset: 0, index: 0)
    let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)
    let groups = MTLSize(width: n / 256, height: 1, depth: 1)
    enc.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    enc.endEncoding()
    cb.commit()
    cb.waitUntilCompleted()
    iters += 1
}
print("done: \(iters) dispatches")
