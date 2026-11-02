import CoreGraphics
import os
import simd

/// A moyl's planet as a picture: a sphere lit from in front of it (from the side its light comes
/// from, `lit` of its disc reached), its surface turning under the light, all in the moyl's own
/// color: a gas giant's bands and storm, an ice giant's haze, an ocean world's seas, land, ice and
/// cloud, a rocky world's craters, or the moon's seas and highlands. Shaded pixel by pixel: the
/// light falling off toward the terminator, softly where there's air to scatter it; the limb
/// darkening a little; seas catching the light; and a thin rim of air on the lit side.
enum Planet {
    enum Surface: Hashable {
        case banded, icy, ocean, rocky, moon
    }

    /// How it's seen and lit (as `Globe` has it): leaning `tilt`, its north pole tipped toward us
    /// by `inclination` and turned `turn` round its axis; the light from `light` (an angle on the
    /// screen, down positive), reaching `lit` (0...1) of the disc.
    struct View {
        var tilt: CGFloat
        var inclination: CGFloat
        var turn: CGFloat
        var light: CGFloat
        var lit: CGFloat
    }

    /// How far its air reaches past its limb, in points.
    static func margin(_ radius: CGFloat) -> CGFloat { max(1, radius * 0.12) }

    /// The picture, `radius` points (and `margin` round it), `scale` pixels to a point; the
    /// planet's middle is the picture's. Laid out as Core Animation shows a bitmap, as
    /// `MoylSprite.bitmap(of:)`'s are.
    static func picture(_ surface: Surface, tone: Tone, cap: Tone?, seed: Double, radius: CGFloat, scale: CGFloat,
                        view: View) -> CGImage? {
        let half = radius + margin(radius), side = Int((2 * half * scale).rounded(.up))
        guard side > 0, radius > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = context.data else { return nil }
        let map = self.map(surface, tone: tone.stepped, cap: cap?.stepped, seed: surface == .moon ? 0.37 : seed)
        let look = Look(surface, tone: tone)
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        // The light: from the side, as far round toward us as lights `lit` of the disc.
        let toward = Float(2 * min(max(view.lit, 0), 1) - 1), across = (1 - toward * toward).squareRoot()
        let light = SIMD3<Float>(Float(cos(view.light)) * across, Float(sin(view.light)) * across, toward)
        let shine = simd_normalize(light + SIMD3(0, 0, 1))
        let (cosTilt, sinTilt) = (Float(cos(view.tilt)), Float(sin(view.tilt)))
        let (cosTip, sinTip) = (Float(cos(view.inclination)), Float(sin(view.inclination)))
        let turn = Float(view.turn), r = Float(radius * scale), middle = Float(side) / 2
        let reach = Float(margin(radius) / radius)

        for row in 0..<side {
            for column in 0..<side {
                let dx = (Float(column) + 0.5 - middle) / r, dy = (Float(row) + 0.5 - middle) / r
                let d = (dx * dx + dy * dy).squareRoot()
                var out = SIMD4<Float>(0, 0, 0, 0)
                // The disc, its edge smoothed over a pixel.
                let cover = min(max((1 - d) * r + 0.5, 0), 1)
                if cover > 0 {
                    let flat = min(d, 1), deep = (1 - flat * flat).squareRoot()
                    let normal = d > 0 ? SIMD3(dx / d * flat, dy / d * flat, deep) : SIMD3<Float>(0, 0, 1)
                    // Back into the planet's own frame: untilted, untipped, unturned.
                    let x = normal.x * cosTilt + normal.y * sinTilt, up = -(-normal.x * sinTilt + normal.y * cosTilt)
                    let y = up * cosTip + normal.z * sinTip, z = normal.z * cosTip - up * sinTip
                    let latitude = asin(min(max(y, -1), 1)), longitude = atan2(x, z) - turn
                    let (albedo, water) = map.sample(latitude: latitude, longitude: longitude)
                    let facing = simd_dot(normal, light)
                    let day = max(0, (facing + look.scatter) / (1 + look.scatter))
                    let limb = 1 - look.limb * (1 - deep.squareRoot())
                    var color = albedo * (Look.night + day * 1.08 * limb)
                    if water > 0, facing > 0 { color += SIMD3(repeating: water * 0.5 * pow(max(simd_dot(normal, shine), 0), 32)) }
                    if look.air > 0 {
                        let rim = pow(1 - deep, 3) * look.air * min(max(facing + 0.35, 0), 1)
                        color += look.airTone * rim
                    }
                    color = simd_clamp(color, SIMD3(repeating: 0), SIMD3(repeating: 1))
                    out = SIMD4(color * cover, cover)
                }
                // Its air past the limb, where the light's on it.
                if look.air > 0, d > 1 - 1 / r, d < 1 + reach {
                    let past = max(d - 1, 0) / reach, lit = min(max((dx * light.x + dy * light.y) / max(d, 0.001) + 0.3 * light.z + 0.25, 0), 1)
                    let haze = (1 - past) * (1 - past) * look.air * 0.55 * lit * (1 - out.w)
                    out += SIMD4(look.airTone * haze, haze)
                }
                // Blue, green, red, then alpha.
                let at = (row * side + column) * 4
                pixels[at] = UInt8(min(out.z, 1) * 255 + 0.5)
                pixels[at + 1] = UInt8(min(out.y, 1) * 255 + 0.5)
                pixels[at + 2] = UInt8(min(out.x, 1) * 255 + 0.5)
                pixels[at + 3] = UInt8(min(out.w, 1) * 255 + 0.5)
            }
        }
        return context.makeImage()
    }

    /// How a surface takes the light: how far it scatters past the terminator, how much its limb
    /// darkens, and how much air it has, in what color.
    private struct Look {
        let scatter: Float
        let limb: Float
        let air: Float
        let airTone: SIMD3<Float>
        /// The night side: not quite black, in the band's sky.
        static let night: Float = 0.06

        init(_ surface: Surface, tone: Tone) {
            let pale = Map.vector(tone.mix(.white, 0.45))
            switch surface {
            case .banded: (scatter, limb, air, airTone) = (0.12, 0.42, 0.3, pale)
            case .icy: (scatter, limb, air, airTone) = (0.2, 0.48, 0.5, pale)
            case .ocean: (scatter, limb, air, airTone) = (0.08, 0.2, 0.6, Map.vector(tone.mix(Tone(red: 0.62, green: 0.82, blue: 1), 0.55)))
            case .rocky: (scatter, limb, air, airTone) = (0.03, 0.05, 0.08, pale)
            case .moon: (scatter, limb, air, airTone) = (0, 0, 0, pale)
            }
        }
    }

    // MARK: The surfaces

    private struct Key: Hashable {
        let surface: Surface
        let tone: Tone
        let cap: Tone?
        let seed: Int
    }

    private static let maps = OSAllocatedUnfairLock(initialState: [Key: Map]())

    /// A surface's map, made once for its color and seed.
    private static func map(_ surface: Surface, tone: Tone, cap: Tone?, seed: Double) -> Map {
        let key = Key(surface: surface, tone: tone, cap: cap, seed: Int((seed * 1000).rounded()))
        if let map = maps.withLock({ $0[key] }) { return map }
        let map = Map(surface, tone: tone, cap: cap, seed: seed)
        maps.withLock {
            // A timer's color deepens as it goes; those gone by needn't be kept.
            if $0.count > 48 { $0 = [:] }
            $0[key] = map
        }
        return map
    }

    /// A surface's colors (and how much of it is open water, to shine) by latitude and longitude.
    private final class Map: Sendable {
        static let width = 256, height = 128
        let colors: [SIMD3<Float>]
        let water: [Float]

        static func vector(_ tone: Tone) -> SIMD3<Float> { SIMD3(Float(tone.red), Float(tone.green), Float(tone.blue)) }

        init(_ surface: Surface, tone: Tone, cap: Tone?, seed: Double) {
            let noise = Noise(seed: UInt32(truncatingIfNeeded: Int(seed * 1_000_003)))
            var random = Scatter(state: UInt64(seed * 4_294_967_296) | 1)
            let base = Self.vector(tone), white = Self.vector(.white), ink = Self.vector(.ink), cream = Self.vector(.starlight)
            func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> { a + (b - a) * min(max(t, 0), 1) }
            func smooth(_ low: Float, _ high: Float, _ x: Float) -> Float {
                let t = min(max((x - low) / (high - low), 0), 1)
                return t * t * (3 - 2 * t)
            }
            // A few spots on it (storms, craters): where, and how big, in radians.
            let spots = (0..<14).map { _ -> (SIMD3<Float>, Float) in
                let latitude = Float(random.range(-1.2, 1.2)), longitude = Float(random.range(-.pi, .pi))
                return (SIMD3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude)), Float(random.range(0.06, 0.24)))
            }
            let bands = Float(random.range(7, 11)), phase = Float(random.range(0, 2 * .pi))
            let storm = (latitude: Float(random.range(-0.5, -0.25)), longitude: Float(random.range(-.pi, .pi)))

            var colors = [SIMD3<Float>](repeating: .zero, count: Self.width * Self.height)
            var water = [Float](repeating: 0, count: Self.width * Self.height)
            for row in 0..<Self.height {
                let latitude = Float.pi / 2 - (Float(row) + 0.5) / Float(Self.height) * .pi
                for column in 0..<Self.width {
                    let longitude = (Float(column) + 0.5) / Float(Self.width) * 2 * .pi - .pi
                    let p = SIMD3(cos(latitude) * sin(longitude), sin(latitude), cos(latitude) * cos(longitude))
                    var color: SIMD3<Float>, wet: Float = 0
                    // How far (in radians) from a spot, and from the storm (stretched along the bands).
                    func away(_ spot: SIMD3<Float>) -> Float { acos(min(max(simd_dot(p, spot), -1), 1)) }
                    switch surface {
                    case .banded:
                        let warp = noise.fbm(p * 2.2 + 11) - 0.5, fine = noise.fbm(p * 7 + 3) - 0.5
                        let v = 0.5 + 0.3 * sin(latitude * bands + warp * 2.6 + phase) + 0.2 * fine
                        color = v < 0.5 ? mix(mix(base, ink, 0.42), base, v * 2) : mix(base, mix(base, white, 0.5), (v - 0.5) * 2)
                        color = mix(color, mix(base, cream, 0.5), 0.3 * (0.5 + 0.5 * sin(latitude * bands * 0.5 + phase * 1.7)))
                        let along = Swift.min(abs(longitude - storm.longitude), 2 * .pi - abs(longitude - storm.longitude))
                        let oval = ((along * 0.45) * (along * 0.45) + (latitude - storm.latitude) * (latitude - storm.latitude)).squareRoot()
                        color = mix(color, mix(mix(base, ink, 0.3), cream, 0.25), smooth(0.13, 0.07, oval))
                        color = mix(color, mix(base, white, 0.55), smooth(0.07, 0.03, oval) * 0.6)
                        color *= 1 - 0.28 * smooth(1.0, 1.45, abs(latitude))
                    case .icy:
                        let haze = noise.fbm(p * 1.6 + 2) - 0.5
                        let v = 0.5 + 0.09 * sin(latitude * 5 + haze * 1.4) + 0.12 * haze
                        color = mix(mix(base, ink, 0.2), mix(base, white, 0.35), v)
                        color = mix(color, mix(base, white, 0.5), smooth(-1.0, -1.35, latitude) * 0.6)
                        let along = Swift.min(abs(longitude - storm.longitude), 2 * .pi - abs(longitude - storm.longitude))
                        let oval = ((along * 0.5) * (along * 0.5) + (latitude - storm.latitude) * (latitude - storm.latitude)).squareRoot()
                        color = mix(color, mix(base, ink, 0.4), smooth(0.11, 0.06, oval))
                        color = mix(color, white, smooth(0.04, 0.0, abs(oval - 0.13)) * 0.35)
                    case .ocean:
                        let land = noise.fbm(p * 1.7 + 5, octaves: 5), detail = noise.fbm(p * 6 + 9)
                        let shore = smooth(0.52, 0.55, land)
                        let sea = mix(mix(base, ink, 0.6), mix(base, ink, 0.32), smooth(0.36, 0.52, land))
                        let ground = mix(mix(base, Self.vector(Tone(red: 0.56, green: 0.5, blue: 0.36)), 0.5), mix(base, cream, 0.4), detail)
                        let ice = smooth(1.18, 1.32, abs(latitude) + 0.08 * (detail - 0.5))
                        let clouds = smooth(0.52, 0.72, noise.fbm(SIMD3(p.x * 3, p.y * 5.5, p.z * 3) + 20, octaves: 5))
                        color = mix(mix(sea, ground, shore), white, Swift.max(ice, clouds * 0.92))
                        wet = (1 - shore) * (1 - clouds) * (1 - ice)
                    case .rocky, .moon:
                        let mottle = noise.fbm(p * 2.5 + 1), fine = noise.fbm(p * 9 + 4)
                        color = mix(mix(base, ink, 0.38), mix(base, white, 0.18), mottle * 0.75 + fine * 0.25)
                        if surface == .moon {
                            // Its seas: dark, smooth plains.
                            color = mix(color, mix(base, ink, 0.5), smooth(0.5, 0.58, noise.fbm(p * 1.3 + 7)) * 0.85)
                        }
                        for (spot, size) in spots {
                            let off = away(spot) / size
                            if off < 1.4 {
                                color *= off < 1 ? 0.82 + 0.1 * off : 1 + 0.16 * smooth(1.4, 1.05, off)
                            }
                        }
                    }
                    if let cap, latitude > 0.9 {
                        // A polar cap, its edge a little ragged, the bands still showing through.
                        let capped = smooth(1.08, 1.16, latitude + 0.08 * (noise.fbm(p * 5 + 13) - 0.5))
                        let shade = 0.82 + 0.3 * noise.fbm(p * 8)
                        color = mix(color, mix(Self.vector(cap), color, 0.3) * shade, capped * 0.85)
                    }
                    colors[row * Self.width + column] = color
                    water[row * Self.width + column] = wet
                }
            }
            self.colors = colors
            self.water = water
        }

        /// The color (and water) at `latitude` and `longitude`, blended from the four nearest.
        func sample(latitude: Float, longitude: Float) -> (SIMD3<Float>, Float) {
            let u = (longitude / (2 * .pi) + 0.5) * Float(Self.width) - 0.5
            let v = min(max((0.5 - latitude / .pi) * Float(Self.height) - 0.5, 0), Float(Self.height - 1))
            let u0 = Int(floor(u)), v0 = Int(v), fu = u - floor(u), fv = v - Float(v0)
            let v1 = min(v0 + 1, Self.height - 1)
            func wrap(_ column: Int) -> Int { ((column % Self.width) + Self.width) % Self.width }
            let a = v0 * Self.width + wrap(u0), b = v0 * Self.width + wrap(u0 + 1)
            let c = v1 * Self.width + wrap(u0), d = v1 * Self.width + wrap(u0 + 1)
            let top = colors[a] + (colors[b] - colors[a]) * fu, bottom = colors[c] + (colors[d] - colors[c]) * fu
            let wetTop = water[a] + (water[b] - water[a]) * fu, wetBottom = water[c] + (water[d] - water[c]) * fu
            return (top + (bottom - top) * fv, wetTop + (wetBottom - wetTop) * fv)
        }
    }

    /// Smooth noise through space, 0...1, its own for each seed.
    private struct Noise {
        let seed: UInt32

        private func hash(_ x: Int32, _ y: Int32, _ z: Int32) -> Float {
            var h = (UInt32(bitPattern: x) &* 0x8DA6_B343) ^ (UInt32(bitPattern: y) &* 0xD816_3841) ^ (UInt32(bitPattern: z) &* 0xCB1A_B31F) ^ seed
            h = (h ^ (h >> 13)) &* 0x5BD1_E995
            h ^= h >> 15
            return Float(h & 0xFF_FFFF) / Float(0xFF_FFFF)
        }

        func value(_ p: SIMD3<Float>) -> Float {
            let cell = floor(p), f = p - cell
            let s = f * f * (SIMD3(repeating: 3) - 2 * f)
            let (x, y, z) = (Int32(cell.x), Int32(cell.y), Int32(cell.z))
            func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
            let front = lerp(lerp(hash(x, y, z), hash(x + 1, y, z), s.x), lerp(hash(x, y + 1, z), hash(x + 1, y + 1, z), s.x), s.y)
            let back = lerp(lerp(hash(x, y, z + 1), hash(x + 1, y, z + 1), s.x), lerp(hash(x, y + 1, z + 1), hash(x + 1, y + 1, z + 1), s.x), s.y)
            return lerp(front, back, s.z)
        }

        /// Octaves of it, each twice as fine and half as strong.
        func fbm(_ p: SIMD3<Float>, octaves: Int = 4) -> Float {
            var sum: Float = 0, amplitude: Float = 0.5, total: Float = 0, p = p
            for _ in 0..<octaves {
                sum += value(p) * amplitude
                total += amplitude
                amplitude *= 0.5
                p = p * 2.03 + SIMD3(17.1, 5.3, 9.7)
            }
            return sum / total
        }
    }

    /// A seeded stream of numbers.
    private struct Scatter {
        var state: UInt64

        mutating func range(_ low: Double, _ high: Double) -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return low + (high - low) * Double(state >> 11) / Double(UInt64(1) << 53)
        }
    }
}
