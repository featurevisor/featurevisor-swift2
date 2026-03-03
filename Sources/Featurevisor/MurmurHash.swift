import Foundation

@inline(__always)
private func rotl32(_ x: UInt32, _ r: UInt32) -> UInt32 {
    (x << r) | (x >> (32 - r))
}

public func murmurhash3(_ key: String, seed: UInt32 = 1) -> UInt32 {
    let data = Array(key.utf8)
    let c1: UInt32 = 0xcc9e2d51
    let c2: UInt32 = 0x1b873593

    var h1 = seed
    let nblocks = data.count / 4

    for i in 0..<nblocks {
        let base = i * 4
        var k1 = UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)

        k1 = k1 &* c1
        k1 = rotl32(k1, 15)
        k1 = k1 &* c2

        h1 ^= k1
        h1 = rotl32(h1, 13)
        h1 = h1 &* 5 &+ 0xe6546b64
    }

    var k1: UInt32 = 0
    let tailIndex = nblocks * 4
    switch data.count & 3 {
    case 3:
        k1 ^= UInt32(data[tailIndex + 2]) << 16
        fallthrough
    case 2:
        k1 ^= UInt32(data[tailIndex + 1]) << 8
        fallthrough
    case 1:
        k1 ^= UInt32(data[tailIndex])
        k1 = k1 &* c1
        k1 = rotl32(k1, 15)
        k1 = k1 &* c2
        h1 ^= k1
    default:
        break
    }

    h1 ^= UInt32(data.count)
    h1 ^= h1 >> 16
    h1 = h1 &* 0x85ebca6b
    h1 ^= h1 >> 13
    h1 = h1 &* 0xc2b2ae35
    h1 ^= h1 >> 16

    return h1
}
