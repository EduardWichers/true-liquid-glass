import CoreGraphics
import Foundation
import simd

/// Screen edge the Dock sits on.
enum DockEdge: Int, CustomStringConvertible {
    case bottom, left, right

    /// Direction from the screen interior towards the Dock (overlay TL coordinates, +y = down).
    var normal: SIMD2<Float> {
        switch self {
        case .bottom: return SIMD2(0, 1)
        case .left: return SIMD2(-1, 0)
        case .right: return SIMD2(1, 0)
        }
    }

    var description: String {
        switch self {
        case .bottom: return "bottom"
        case .left: return "left"
        case .right: return "right"
        }
    }

    static func fromOrientation(_ value: String?) -> DockEdge {
        switch value?.lowercased() {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }
}

/// Which effect plays.
enum LiquidEffect: Int {
    /// Yellow button: the window melts into water that drains into the Dock.
    case water = 0
    /// Red button: the window heats up and evaporates into rising steam.
    case steam = 1
}

/// One drop of water. Layout must match `struct Particle` in `LiquidShaders` (4 x float4 = 64 bytes).
///
/// Two motion modes (d.w):
///  - 1 = gravity (Dock at the bottom): free fall onto the Dock, splash, then the water
///        runs along the Dock as a thin film and drains into the icon.
///        b = (horizontal start speed, gravity, landing y, flow duration)
///  - 0 = curve (Dock left/right): a cubic bezier that first falls and then bends into the icon.
///        b = (control1.xy, control2.xy)
///  - 2 = steam: a puff that rises (buoyancy), drifts, swirls, grows and fades.
///        a = (start.xy, horizontal drift, rise speed), b = (buoyancy, turbulence, growth, 0)
struct LiquidParticle {
    var a: SIMD4<Float>  // start.xy, drain point.xy                (points, overlay TL)
    var b: SIMD4<Float>  // mode dependent, see above
    var c: SIMD4<Float>  // uv.xy in window texture, release time, travel duration (animation seconds)
    var d: SIMD4<Float>  // radius (points), phase, splash height / wobble (points), mode
}

/// Layout must match `struct Uniforms` in `LiquidShaders` (10 x float4 = 160 bytes).
struct LiquidUniforms {
    var view: SIMD4<Float>    // overlay width, height (points), render-target pixels per point x, y
    var time: SIMD4<Float>    // t, total duration, dissolve time, click-ripple strength
    var win: SIMD4<Float>     // window origin x, y, width, height (points, TL)
    var melt: SIMD4<Float>    // meltStart, meltSpan, jitter, sag acceleration
    var points: SIMD4<Float>  // drain target x, y, ripple origin x, y
    var misc: SIMD4<Float>    // field threshold, opaque background (0/1), corner radius, fade window
    var dock: SIMD4<Float>    // first arrival, last arrival, dock edge normal x, y
    var fluid: SIMD4<Float>   // 1 / fluid texture width, 1 / fluid texture height, 1 / resting field, 0
    var water: SIMD4<Float>   // water colour r, g, b (display P3), colour strength
    var effect: SIMD4<Float>  // effect (0 water, 1 steam), 0, 0, 0
}

/// The melt schedule. These formulas are mirrored 1:1 in the Metal shader
/// (`releaseTime`, `sagAt`, `dripNoise`); keep them in sync.
struct LiquidTimeline {
    var effect: LiquidEffect = .water
    var meltStart: Float = 0.16
    var meltSpan: Float = 0.40
    var jitter: Float = 0.08
    var sagDistance: Float = 40
    /// The solid window fades out (and the drop fades in) over this many seconds around the release moment.
    var fadeWindow: Float = 0.05
    /// Seconds after which a drop has lost the window's colours and is plain water.
    var dissolveTime: Float = 0.35

    /// Mostly flat with narrow positive peaks: those columns melt later, so the solid part
    /// hangs down in drips. Range [-1, 1].
    static func dripNoise(_ x: Float) -> Float {
        let a = pow(max(0, 0.5 + 0.5 * sin(x * 23.0 + 1.3)), 8.0)
        let b = 0.7 * pow(max(0, 0.5 + 0.5 * sin(x * 37.0 + 4.1)), 10.0)
        let c = 0.25 * sin(x * 6.0 + 2.0)
        return (a + b + c - 0.85) / 1.1
    }

    /// Steam: the window evaporates from the edges inwards in irregular patches. Range [0, 1].
    static func steamOrder(_ u: Float, _ v: Float) -> Float {
        let edge = min(min(u, 1 - u), min(v, 1 - v)) * 2
        let n = 0.5 + 0.22 * sin(u * 11.0 + v * 7.3 + 1.7) + 0.16 * sin(u * 23.1 - v * 17.9 + 0.4)
            + 0.12 * sin(u * 41.7 + v * 37.3 + 2.9)
        return min(max(0.55 * n + 0.45 * edge, 0), 1)
    }

    /// Moment (animation seconds) at which the window pixel at normalized (lx, ly) turns liquid
    /// (or into steam). For water `ly` is measured from the top, so the bottom edge melts first
    /// and the drips come from `dripNoise`.
    func releaseTime(lx: Float, ly: Float) -> Float {
        if effect == .steam { return meltStart + meltSpan * LiquidTimeline.steamOrder(lx, ly) }
        return meltStart + (1 - ly) * meltSpan + LiquidTimeline.dripNoise(lx) * jitter
    }

    static func steam() -> LiquidTimeline {
        var timeline = LiquidTimeline()
        timeline.effect = .steam
        timeline.meltStart = 0.10
        timeline.meltSpan = 0.55
        timeline.jitter = 0
        timeline.sagDistance = 0
        timeline.fadeWindow = 0.06
        timeline.dissolveTime = 0.30
        return timeline
    }

    /// How far (points) the still-solid part of the window has sagged at time t.
    func sag(at t: Float) -> Float {
        let d = max(0, t - meltStart)
        return 0.5 * sagAccel * d * d
    }

    var sagAccel: Float { meltSpan > 0 ? 2 * sagDistance / (meltSpan * meltSpan) : 0 }

    var earliestRelease: Float { effect == .steam ? meltStart : meltStart - jitter }
    var latestRelease: Float { effect == .steam ? meltStart + meltSpan : meltStart + meltSpan + jitter }
}

struct LiquidSceneInput {
    /// Overlay size in points.
    var viewSize: CGSize
    /// Window frame in overlay TL points.
    var windowRect: CGRect
    /// Where the water drains into (Dock icon), overlay TL points.
    var target: CGPoint
    /// Origin of the ripple that runs over the window (the clicked minimize button).
    var rippleOrigin: CGPoint
    var edge: DockEdge
    /// Drops end at spots inside this radius around the target.
    var drainRadius: CGFloat
    /// Surface the falling water lands on (top of the Dock), overlay TL y. Used for a bottom Dock.
    var floorY: CGFloat
    /// True when a clean background plate is available (system-wide mode).
    var opaqueBackground: Bool
    /// Water colour, display-P3 components 0...1.
    var waterColor: SIMD3<Float>
    /// 0 = nearly clear water, 1 = deeply coloured.
    var colorStrength: Float
    var cornerRadius: Float
    var effect: LiquidEffect = .water
    var maxParticles: Int = 42_000
    var seed: UInt64 = 0x5EED_CAFE
    /// Alpha of the window image at normalized coordinates (0...1, top-left origin).
    var alphaAt: (Float, Float) -> Float
}

enum LiquidSceneError: Error, LocalizedError {
    case invalidGeometry(String)

    var errorDescription: String? {
        switch self {
        case .invalidGeometry(let what): return "Invalid geometry for the animation: \(what)"
        }
    }
}

/// Deterministic random generator so a scene is reproducible (handy for tests).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func nextFloat() -> Float { Float(next() >> 40) / Float(1 << 24) }
}

/// Everything the renderer needs for one minimize animation.
struct LiquidScene {
    let input: LiquidSceneInput
    let timeline: LiquidTimeline
    let particles: [LiquidParticle]
    /// Animation seconds until the last drop has drained.
    let totalDuration: Float
    let firstArrival: Float
    let lastArrival: Float
    let spacing: Float
    /// Gravity used for the free fall (points / s²); 0 when the curve mode is used.
    let gravity: Float
    /// Fluid texture texels per point (steam is soft, so half resolution is enough).
    let fluidScale: Float
    /// Field value of a resting, densely packed sheet for this effect.
    let restingField: Float

    static let fieldThreshold: Float = 0.5
    /// Drop radius relative to the grid spacing (large overlap = smooth water).
    static let radiusFactor: Float = 2.6
    static let steamRadiusFactor: Float = 2.8
    static let maxSteamParticles = 9_000
    /// Field value inside a resting, densely packed area: sum of (1 - d²/r²)³ over the grid ≈ π k² / 4
    /// (water kernel) or π k² / 3 for the softer steam kernel (1 - d²/r²)².
    static func restingField(for effect: LiquidEffect) -> Float {
        switch effect {
        case .water: return Float.pi * radiusFactor * radiusFactor / 4
        case .steam: return Float.pi * steamRadiusFactor * steamRadiusFactor / 3
        }
    }
    /// The highest drop lands within this time (keeps very tall windows/screens snappy).
    static let maxFallTime: Float = 0.55

    static func build(_ input: LiquidSceneInput) throws -> LiquidScene {
        let view = input.viewSize
        guard view.width.isFinite, view.height.isFinite, view.width >= 1, view.height >= 1 else {
            throw LiquidSceneError.invalidGeometry("overlay size \(view)")
        }
        guard ScreenGeometry.isValid(input.windowRect), input.windowRect.width >= 2, input.windowRect.height >= 2 else {
            throw LiquidSceneError.invalidGeometry("window frame \(input.windowRect)")
        }
        guard input.target.x.isFinite, input.target.y.isFinite,
              input.rippleOrigin.x.isFinite, input.rippleOrigin.y.isFinite else {
            throw LiquidSceneError.invalidGeometry("target \(input.target) / ripple \(input.rippleOrigin)")
        }
        guard input.maxParticles > 0 else { throw LiquidSceneError.invalidGeometry("maxParticles = 0") }

        let w = Float(input.windowRect.width)
        let h = Float(input.windowRect.height)
        let steam = input.effect == .steam
        var timeline = steam ? LiquidTimeline.steam() : LiquidTimeline()
        if !steam { timeline.sagDistance = min(h * 0.18, 90) }

        let budget = steam ? min(input.maxParticles, LiquidScene.maxSteamParticles) : input.maxParticles
        let spacing = max(3.0, (w * h / Float(budget)).squareRoot())
        let cols = max(1, Int((w / spacing).rounded(.up)))
        let rows = max(1, Int((h / spacing).rounded(.up)))

        var rng = SplitMix64(seed: input.seed)
        var particles: [LiquidParticle] = []
        particles.reserveCapacity(min(cols * rows, budget * 2))

        let origin = SIMD2<Float>(Float(input.windowRect.minX), Float(input.windowRect.minY))
        let target = SIMD2<Float>(Float(input.target.x), Float(input.target.y))
        let normal = input.edge.normal
        let drain = Float(max(2, min(input.drainRadius, 60)))
        let useGravity = input.edge == .bottom && !steam
        let center = origin + SIMD2(w / 2, h / 2)

        // Gravity: the landing surface is the top of the Dock (never below the screen, never
        // above the drain point). Strong enough that the highest drop lands within maxFallTime.
        let floorInput = input.floorY.isFinite ? Float(input.floorY) : target.y - 26
        let floorBase = min(max(floorInput, 4), Float(view.height) - 2, max(target.y, 4))
        let maxDrop = max(1, floorBase - origin.y)
        let gravity: Float = useGravity ? max(6500, 2 * maxDrop / (maxFallTime * maxFallTime)) : 0

        var firstArrival = Float.greatestFiniteMagnitude
        var lastArrival: Float = 0
        var endOfMotion: Float = 0

        // Lateral axis inside the drain (keeps the left/right order of the stream intact).
        let lateral: SIMD2<Float> = input.edge == .bottom ? SIMD2(1, 0) : SIMD2(0, 1)

        for j in 0..<rows {
            for i in 0..<cols {
                let jx = (rng.nextFloat() - 0.5) * 0.5 * spacing
                let jy = (rng.nextFloat() - 0.5) * 0.5 * spacing
                let lx = min(max((Float(i) + 0.5) * spacing + jx, 0), w)
                let ly = min(max((Float(j) + 0.5) * spacing + jy, 0), h)
                let u = lx / w
                let v = ly / h
                let alpha = input.alphaAt(u, v)
                // Draw the random numbers even for skipped drops so the scene stays deterministic.
                let r1 = rng.nextFloat(), r2 = rng.nextFloat(), r3 = rng.nextFloat()
                let r4 = rng.nextFloat(), r5 = rng.nextFloat(), r6 = rng.nextFloat()
                guard alpha.isFinite, alpha > 0.15 else { continue }

                let release = timeline.releaseTime(lx: u, ly: v)
                let start = origin + SIMD2(lx, ly + timeline.sag(at: release))

                // Neighbouring drops get (almost) the same path so the water stays one
                // coherent stream instead of scattering into loose grains.
                let order = (input.edge == .bottom ? u : v) - 0.5
                let end = target + lateral * (order * drain * 1.6) + normal * ((r1 - 0.5) * drain * 0.5)
                let dropRadius = spacing * LiquidScene.radiusFactor * (0.95 + 0.1 * r6)
                let phase = u * 1.7 + v * 0.6   // coherent phase (no wrap-around jumps)

                let particle: LiquidParticle
                let travel: Float
                let arrival: Float
                if steam {
                    // Warm air rises and accelerates (buoyancy); puffs drift away from the
                    // middle of the window, swirl and spread out while they fade.
                    let outward = (start - center) / SIMD2(max(w, 1), max(h, 1))
                    let drift = outward.x * 90 + (r1 - 0.5) * 50
                    let rise = 90 + 80 * r2
                    let buoyancy = 220 + 160 * r3
                    let turbulence = 14 + 14 * r4
                    let growth = 2.6 + 1.4 * r5
                    travel = 0.65 + 0.3 * r6
                    arrival = Float(1_000)
                    // Mostly position based, so neighbouring puffs swirl together into wisps.
                    let phase = u * 2.0 + v * 1.3 + r1 * 0.6
                    particle = LiquidParticle(a: SIMD4(start.x, start.y, drift, rise),
                                              b: SIMD4(buoyancy, turbulence, growth, 0),
                                              c: SIMD4(u, v, release, travel),
                                              d: SIMD4(spacing * LiquidScene.steamRadiusFactor, phase, 0, 2))
                } else if useGravity {
                    // The water film on the Dock has some thickness.
                    let floorY = max(floorBase - r2 * 7, start.y)
                    // Neighbouring strands fall slightly differently, so the falling curtain
                    // tears into strands and drops like real water.
                    let strand = 1 + 0.035 * sin(u * 23.0 + 0.7) + 0.02 * sin(u * 61.0 + 2.1)
                    let g = gravity * strand * (0.995 + 0.01 * r3)
                    let landing = (2 * (floorY - start.y) / g).squareRoot()
                    // A little drift towards the drain while falling.
                    let vx0 = landing > 0.02 ? (end.x - start.x) * 0.22 / landing : 0
                    let xLand = start.x + vx0 * landing
                    let flow = min(max(abs(end.x - xLand) / 1600 + 0.14, 0.2), 0.62)
                    let splash: Float = r4 < 0.3 ? 4 + 16 * r5 : 0
                    travel = landing + flow
                    arrival = release + landing + flow * 0.75
                    particle = LiquidParticle(a: SIMD4(start.x, start.y, end.x, end.y),
                                              b: SIMD4(vx0, g, floorY, flow),
                                              c: SIMD4(u, v, release, travel),
                                              d: SIMD4(dropRadius, phase, splash, 1))
                } else {
                    let dist = simd_length(end - start)
                    let smooth = 0.5 + 0.5 * sin(u * 9.1 + v * 5.3)
                    travel = min(max(0.38 + dist / 2200, 0.42), 0.95) * (0.97 + 0.06 * smooth) * (0.99 + 0.02 * r3)
                    // First fall, then bend into the Dock icon from the inside of the screen.
                    let fall = max(30, 0.3 * dist)
                    let c1 = start + SIMD2(sin(u * 7.3 + v * 2.1) * 5, fall)
                    let approach = max(40, 0.35 * dist)
                    let c2 = end - normal * approach + lateral * (order * approach * 0.5)
                    arrival = release + travel * 0.8
                    particle = LiquidParticle(a: SIMD4(start.x, start.y, end.x, end.y),
                                              b: SIMD4(c1.x, c1.y, c2.x, c2.y),
                                              c: SIMD4(u, v, release, travel),
                                              d: SIMD4(dropRadius, phase, 3.5, 0))
                }
                particles.append(particle)
                firstArrival = min(firstArrival, arrival)
                lastArrival = max(lastArrival, steam ? arrival : release + travel)
                endOfMotion = max(endOfMotion, release + travel)
            }
        }

        if particles.isEmpty {
            firstArrival = steam ? 1_000 : timeline.latestRelease
            lastArrival = steam ? 1_000 : timeline.latestRelease
        }
        let total = max(endOfMotion, timeline.latestRelease) + 0.12

        var adjusted = input
        adjusted.waterColor = SIMD3(LiquidScene.unit(input.waterColor.x, 0.62),
                                    LiquidScene.unit(input.waterColor.y, 0.84),
                                    LiquidScene.unit(input.waterColor.z, 0.98))
        adjusted.colorStrength = LiquidScene.unit(input.colorStrength, 0.45)
        return LiquidScene(input: adjusted, timeline: timeline, particles: particles,
                           totalDuration: total, firstArrival: firstArrival, lastArrival: lastArrival,
                           spacing: spacing, gravity: gravity, fluidScale: steam ? 0.5 : 1,
                           restingField: LiquidScene.restingField(for: input.effect))
    }

    private static func unit(_ v: Float, _ fallback: Float) -> Float {
        v.isFinite ? min(max(v, 0), 1) : fallback
    }

    func uniforms(time t: Float, scaleX: Float, scaleY: Float, fluidTexel: SIMD2<Float>) -> LiquidUniforms {
        let r = input.windowRect
        let c = input.waterColor
        return LiquidUniforms(
            view: SIMD4(Float(input.viewSize.width), Float(input.viewSize.height), scaleX, scaleY),
            time: SIMD4(t, totalDuration, timeline.dissolveTime, 1),
            win: SIMD4(Float(r.minX), Float(r.minY), Float(r.width), Float(r.height)),
            melt: SIMD4(timeline.meltStart, timeline.meltSpan, timeline.jitter, timeline.sagAccel),
            points: SIMD4(Float(input.target.x), Float(input.target.y),
                          Float(input.rippleOrigin.x), Float(input.rippleOrigin.y)),
            misc: SIMD4(LiquidScene.fieldThreshold, input.opaqueBackground ? 1 : 0,
                        input.cornerRadius, timeline.fadeWindow),
            dock: SIMD4(firstArrival, lastArrival, input.edge.normal.x, input.edge.normal.y),
            fluid: SIMD4(fluidTexel.x, fluidTexel.y, 1 / restingField, 0),
            water: SIMD4(c.x, c.y, c.z, input.colorStrength),
            effect: SIMD4(Float(input.effect.rawValue), 0, 0, 0))
    }
}
