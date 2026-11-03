// Dockosaur: an endless runner that lives on top of the macOS Dock.
//
// Art (see README for links and licences):
//   dinos            Arks (@ArksDigital), CC BY 4.0
//   spikes/crates/saw/fruit/dust/font  Pixel Frog, CC0
//   pterodactyls     drawn for Dockosaur by Tools/ptero.swift
//
// Units: game distances are art pixels ("px"), times are seconds. One px is drawn as
// `scale` points (2 by default), so the art stays crisp on Retina screens.

import Cocoa
import Carbon.HIToolbox
import AVFoundation
import ServiceManagement

// MARK: - Tunables

enum K {
    static let below = 3.0           // strip height under the ground surface (ground line + pebbles)
    static let above = 53.0          // strip height over the ground surface
    static let dinoX = 14.0          // dino frame origin; its body starts 4 px in
    static let jumpV = 215.0         // take-off speed  -> apex ≈ 33 px
    static let gravity = 700.0
    static let releaseV = 80.0       // letting go early caps the upward speed (short hop)
    static let startSpeed = 150.0
    static let maxSpeed = 380.0
    static let accel = 1.6           // px/s gained per second
    static let pxPerPoint = 15.0     // 1 point per 15 px run
    static let fruitBonus = 50.0
    static let highBirdBottom = 21.0 // dino head is ~17 px tall: stay on the ground to pass under
    static let lowBirdBottom = 3.0   // gliders skim the ground: jump them
    static let smashBonus = 10.0
    static let bigScale = 1.75       // strawberry: the dino grows this much and smashes what it touches
    static let bigTime = 6.0
    static let turboTime = 5.0       // juice box: the dino skates itself at turbo speed
    static let skateLift = 3.0       // the wheels raise the dino this much (drawing only)
    static let turboMul = 1.8
    static let grace = 0.9           // invincible this long after a power wears off
    static let pitOpenLead = 0.15    // a pit caves in this many seconds before the dino reaches it
}

// MARK: - Small helpers

struct RNG {   // SplitMix64: deterministic for snapshots and the self-test
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Opaque-pixel map of a sprite frame, row 0 at the bottom (world y grows upward).
struct Mask {
    let w: Int, h: Int
    let bits: [Bool]
    let box: CGRect                  // opaque bounds, row 0 at the bottom
    init(w: Int, h: Int, bits: [Bool]) {
        self.w = w; self.h = h; self.bits = bits
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        for y in 0..<h { for x in 0..<w where bits[y * w + x] { x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + 1); y1 = max(y1, y + 1) } }
        box = x1 > x0 ? CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .zero
    }
    func solid(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && bits[y * w + x] }
    var padBottom: Int { for y in 0..<h { for x in 0..<w where bits[y * w + x] { return y } }; return h }
    var padLeft: Int { for x in 0..<w { for y in 0..<h where bits[y * w + x] { return x } }; return w }
    var isEmpty: Bool { !bits.contains(true) }
    /// Drops the outline ring so grazing a tail or a spike tip doesn't count as a hit.
    func eroded() -> Mask {
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w where solid(x, y) {
            out[y * w + x] = solid(x - 1, y) && solid(x + 1, y) && solid(x, y - 1) && solid(x, y + 1)
        } }
        return Mask(w: w, h: h, bits: out)
    }
}

func overlaps(_ a: Mask, _ ax: Int, _ ay: Int, _ b: Mask, _ bx: Int, _ by: Int) -> Bool {
    let x0 = max(ax, bx), x1 = min(ax + a.w, bx + b.w)
    let y0 = max(ay, by), y1 = min(ay + a.h, by + b.h)
    if x0 >= x1 || y0 >= y1 { return false }
    for y in y0..<y1 { for x in x0..<x1 where a.solid(x - ax, y - ay) && b.solid(x - bx, y - by) { return true } }
    return false
}

struct Frame { let image: CGImage; let mask: Mask }

func maskOf(_ img: CGImage) -> Mask {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var bits = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w { bits[y * w + x] = buf[((h - 1 - y) * w + x) * 4 + 3] > 40 } }  // memory row 0 = top
    return Mask(w: w, h: h, bits: bits)
}

let artDir: URL = {
    let bundled = Bundle.main.resourceURL!.appendingPathComponent("Art")
    if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Art")
}()

func loadPNG(_ name: String) -> CGImage {
    let url = artDir.appendingPathComponent(name + ".png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("missing art: \(url.path)") }
    return img
}

func slice(_ img: CGImage, fw: Int, fh: Int, row: Int = 0, count: Int) -> [Frame] {
    (0..<count).map { i in
        let f = img.cropping(to: CGRect(x: i * fw, y: row * fh, width: fw, height: fh))!
        return Frame(image: f, mask: maskOf(f))
    }
}

// MARK: - Art

let characters: [(id: String, name: String)] = [
    ("vita", "Vita (green)"), ("doux", "Doux (blue)"), ("mort", "Mort (red)"), ("tard", "Tard (yellow)"),
]

/// Tiny hand-drawn sprites: one character per pixel, row 0 at the top. Colours are 0xRRGGBBAA.
func pixelImage(_ rows: [String], _ pal: [Character: UInt32]) -> CGImage {
    let h = rows.count, w = rows.map(\.count).max() ?? 1
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    for (y, row) in rows.enumerated() {
        for (x, ch) in row.enumerated() {
            guard let c = pal[ch] else { continue }
            let a = UInt32(c & 0xff), i = (y * w + x) * 4
            buf[i] = UInt8((c >> 24) * a / 255); buf[i + 1] = UInt8((c >> 16 & 0xff) * a / 255)
            buf[i + 2] = UInt8((c >> 8 & 0xff) * a / 255); buf[i + 3] = UInt8(a)
        }
    }
    return buf.withUnsafeMutableBytes { p in
        CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    }
}

typealias Glyphs = [Character: (white: CGImage, black: CGImage)]

final class Art {
    private(set) var dino: [Frame] = []       // 0-3 idle, 4-9 run, 10-12 kick, 13-16 hurt, 17-23 crouch
    private(set) var dinoHit: [Mask] = []
    let shadow = loadPNG("shadow")
    let spike: Frame
    let boxes: [Frame]
    let saw: [Frame]
    let birds: [[Frame]]                      // pterodactyls: [purple, rust] x 5 wing frames, facing left
    let birdPadLeft: [Int], birdPadBottom: [Int]
    let fruits: [[Frame]]                     // see `Fruit` for the order
    let poof: [CGImage]
    let dust = loadPNG("dust")
    let juiceHeld: [CGImage]                  // turbo: the box the dino sips from (3 slurp frames)
    let skates: [CGImage]                     // turbo: roller skates (2 wheel frames)
    let pebble: Frame                         // red marker stone where a pit will open
    let signs: [Frame]                        // "PIT AHEAD", "FIRE PIT AHEAD": half-pixel resolution (Part.scale 0.5)
    let flames: [Frame]                       // fire pit tongues, 4 flicker frames
    private(set) var glyphs: Glyphs = [:]
    private var holes: [Int: CGImage] = [:]

    init(character: String) {
        spike = slice(loadPNG("spikes"), fw: 16, fh: 16, count: 1)[0]
        boxes = [slice(loadPNG("box1"), fw: 28, fh: 24, count: 1)[0], slice(loadPNG("box2"), fw: 28, fh: 24, count: 1)[0]]
        saw = slice(loadPNG("saw"), fw: 38, fh: 38, count: 8)
        let b = loadPNG("ptero")
        birds = [slice(b, fw: 32, fh: 32, row: 0, count: 5), slice(b, fw: 32, fh: 32, row: 1, count: 5)]
        birdPadLeft = birds.map { $0.map(\.mask.padLeft).min()! }
        birdPadBottom = birds.map { $0.map(\.mask.padBottom).min()! }
        let cherries = slice(loadPNG("fruit_cherries"), fw: 32, fh: 32, count: 17)
        fruits = [cherries, Art.juiceBox(), slice(loadPNG("fruit_strawberry"), fw: 32, fh: 32, count: 17),
                  slice(loadPNG("fruit_orange"), fw: 32, fh: 32, count: 17)]
        let held = [".......", "sssss..", "....s..", "..aaaaaa", "..aLLLda", "..aOROea", "..aOOOea", "..aLLLda", "..aaaaaa"]
        juiceHeld = (0..<3).map { f in
            var rows = held
            rows[1] = Array(rows[1]).enumerated().map { i, c in i == [3, 2, 0][f] ? "j" : String(c) }.joined()   // a sip travels up the straw
            if f == 2 { rows[4] = "...aLLda"; rows[7] = "...aLLda" }                                             // squeezed carton
            return pixelImage(rows, Art.juicePalette)
        }
        skates = [".awa....awa.", ".aWa....aWa."].map {
            pixelImage([".aaaaaaaaaa.", "abbbbbwbbbba", "aaaaaaaaaaaa", $0, "..a......a.."],
                       ["a": 0x2a1d0eff, "b": 0xd8322aff, "w": 0xffffffff, "W": 0x8a8a8aff])
        }
        poof = slice(loadPNG("poof"), fw: 32, fh: 32, count: 6).map(\.image)
        let white = loadPNG("font_white"), black = loadPNG("font_black")
        let rows = ["ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZ", "0123456789", ".,:?!()+-"]
        var g: Glyphs = [:]
        for (r, chars) in rows.enumerated() {
            for (i, c) in chars.enumerated() {
                let rect = CGRect(x: i * 8, y: r * 10, width: 8, height: 10)
                g[c] = (white.cropping(to: rect)!, black.cropping(to: rect)!)
            }
        }
        let peb = pixelImage([".aaaa.", "abccba", "abbbba", ".aaaa."],
                             ["a": 0x4a1010ff, "b": 0xd8322aff, "c": 0xff9a8aff])
        pebble = Frame(image: peb, mask: maskOf(peb))
        signs = ["PIT AHEAD", "FIRE PIT AHEAD"].map { let s = Art.makeSign($0, g); return Frame(image: s, mask: maskOf(s)) }
        flames = [11, 9, 12, 10].enumerated().map { f, h in let img = Art.flame(f, h); return Frame(image: img, mask: maskOf(img)) }
        glyphs = g
        setCharacter(character)
    }

    func setCharacter(_ id: String) {
        let valid = characters.contains { $0.id == id } ? id : "vita"
        dino = slice(loadPNG("dino_" + valid), fw: 24, fh: 24, count: 24)
        dinoHit = dino.map { $0.mask.eroded() }
    }

    /// The hole left when a pit caves in: `w` px wide, as deep as the strip goes under the ground.
    func hole(_ w: Int, fire: Bool) -> CGImage {
        let key = fire ? -w : w
        if let h = holes[key] { return h }
        let k = String(repeating: "k", count: max(0, w - 4))
        var rows = ["dd" + k + "dd", "d" + k + "kkd", "k" + k + "kkk"]
        if fire {   // glowing embers: the top row flickers orange, the bed burns red
            rows[0] = "dd" + String(k.enumerated().map { i, _ in i % 3 == 0 ? "o" : "r" }) + "dd"
            rows[1] = "d" + String(repeating: "r", count: w - 2) + "d"
            rows[2] = String(repeating: "e", count: w)
        }
        let img = pixelImage(rows, ["d": 0x6b4a2bff, "k": 0x120c08ee, "o": 0xff9a2aff, "r": 0xd8322aff, "e": 0x6a1208ff])
        holes[key] = img
        return img
    }

    /// One flame tongue, 7 px wide: yellow core, orange body, red edge, swaying a little per frame.
    private static func flame(_ f: Int, _ h: Int) -> CGImage {
        let w = 7
        let rows = (0..<12).map { r -> String in
            let y = 11 - r                                     // height above the ground
            guard y < h else { return String(repeating: ".", count: w) }
            let t = Double(y) / Double(h)
            let half = 3.4 * (1 - pow(t, 1.4)) + 0.4
            let cx = 3 + sin(Double(f) * .pi / 2 + Double(y) * 0.55) * t * 1.3
            return String((0..<w).map { x -> Character in
                let d = abs(Double(x) - cx) / half
                if d > 1 { return "." }
                if d < 0.4 && t < 0.55 { return "y" }
                return d < 0.75 && t < 0.85 ? "o" : "r"
            })
        }
        return pixelImage(rows, ["y": 0xffe066ff, "o": 0xff8a1aff, "r": 0xd8322aff])
    }

    static let juicePalette: [Character: UInt32] = [
        "a": 0x2a1d0eff, "L": 0xeef6ffff, "d": 0xc4d2e2ff, "O": 0xff9a2aff, "e": 0xd8781aff,
        "R": 0xd8322aff, "g": 0x3c8a2aff, "s": 0xff6a9aff, "j": 0xffb02aff,
    ]

    /// The pickup that replaces the apple: a juice carton with a bent straw, bobbing like the fruit do.
    private static func juiceBox() -> [Frame] {
        let box = ["........ss", ".......s..", ".......s..", ".aaaaaaaa.", "aLLLLLLLda", "aLLLLLLLda", "aOOOgOOOea",
                   "aOORROOOea", "aORRRROOea", "aOORROOOea", "aOOOOOOOea", "aLLLLLLLda", "aaaaaaaaaa"]
        return (0..<17).map { f in
            let dy = Int((sin(Double(f) / 17 * 2 * .pi) * 1.5).rounded())
            let top = 10 + dy
            let rows = (0..<32).map { y -> String in
                let r = y - top
                guard r >= 0 && r < box.count else { return String(repeating: ".", count: 32) }
                return String(repeating: ".", count: 11) + box[r] + String(repeating: ".", count: 11)
            }
            let img = pixelImage(rows, juicePalette)
            return Frame(image: img, mask: maskOf(img))
        }
    }

    /// A yellow warning board on a post, in half-px units so the pixel font fits.
    private static func makeSign(_ text: String, _ glyphs: Glyphs) -> CGImage {
        let tw = text.reduce(0) { $0 + ($1 == " " ? 4 : 7) } - 1
        let W = (tw + 11) / 2 * 2, postH = 20, H = postH + 16
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .none
        func fill(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ rgb: UInt32) {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(rgb >> 16) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                                     blue: CGFloat(rgb & 0xff) / 255, alpha: 1))
            ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        }
        let ink = 0x2a1d0e as UInt32
        fill(W / 2 - 4, 0, 8, postH + 2, ink)               // post
        fill(W / 2 - 2, 0, 4, postH, 0x8a5a2b)
        fill(0, postH, W, 16, ink)                          // board
        fill(2, postH + 2, W - 4, 12, 0xffcc33)
        fill(2, postH + 2, W - 4, 2, 0xd89a1c)
        fill(2, postH + 12, W - 4, 2, 0xffe680)
        var cx = (W - tw) / 2 - 1                           // glyph ink starts 1 px into its cell
        for ch in text {
            if ch == " " { cx += 4; continue }
            if let g = glyphs[ch] { ctx.draw(g.black, in: CGRect(x: cx, y: postH + 3, width: 8, height: 10)) }
            cx += 7
        }
        return ctx.makeImage()!
    }
}

// MARK: - Game model

enum Phase { case idle, running, dead }
enum Sfx { case jump, point, hit, fruit, power, smash, crumble, fire }

/// Strawberry = big (smashes everything), juice box = turbo (skates and dodges by itself, sipping).
enum Power { case none, big, turbo }
enum Fruit { static let cherry = 0, juice = 1, strawberry = 2, orange = 3 }   // indexes into Art.fruits

enum Kind {
    case spikes(Int), box(Int), saw, bird(Int, high: Bool), fruit(Int), pit(Int, fire: Bool), sign(fire: Bool)
}

struct Thing {
    var kind: Kind
    var x: Double          // left edge of the visible body
    var y: Double = 0      // body bottom (fruit); pits: the moment they opened (in `t` time)
    var t: Double = 0
    var gone = false
    var opened = false     // pits only: the ground has caved in
    var width: Double {
        switch kind {
        case .spikes(let n): return Double(n * 15)
        case .box: return 20
        case .saw: return 38
        case .bird: return 27
        case .fruit: return 14
        case .pit(let w, _): return Double(w)
        case .sign(let fire): return fire ? 51 : 35
        }
    }
    var isFruit: Bool { if case .fruit = kind { return true }; return false }
    var isPit: Bool { if case .pit = kind { return true }; return false }
    var isBox: Bool { if case .box = kind { return true }; return false }
    var isFirePit: Bool { if case .pit(_, true) = kind { return true }; return false }
    /// Hurts on contact. Pits hurt by falling in instead; signs are scenery.
    var isSolid: Bool { switch kind { case .fruit, .pit, .sign: return false; default: return true } }
    var isHighBird: Bool { if case .bird(_, let high) = kind { return high }; return false }
    var extraSpeed: Double { if case .bird = kind { return 22 }; return 0 }
}

struct Part { let frame: Frame; let x: Double; let y: Double; var scale = 1.0 }   // frame origin in world px

struct Effect {
    enum Look { case dust, poof, text(String) }
    var look: Look
    var x: Double, y: Double
    var t = 0.0
    var life: Double
}

final class Game {
    let art: Art
    var phase = Phase.idle
    var paused = false
    var worldW = 360.0
    var dinoY = 0.0, vy = 0.0, onGround = true, holding = false, falling = false
    var speed = K.startSpeed, score = 0.0, best = 0
    var things: [Thing] = []
    var fx: [Effect] = []
    var gapLeft = 0.0
    var clock = 0.0, runPhase = 0.0, deadAt = -100.0, bufferedJump = -100.0, flashAt = -100.0
    var playTime = 0.0     // only ticks while running, so power-ups don't run out during a pause
    var power = Power.none, powerStart = 0.0, powerEnd = 0.0, graceEnd = -100.0
    var flipStart = -1.0, flipDur = 0.5   // somersault over a crate (drawing only; the hitbox doesn't spin)
    private(set) var turboBumps = 0  // hits the turbo autopilot failed to dodge (absorbed): self-test metric
    var scroll = 0.0
    var rng: RNG
    var autopilot = false
    private var aiRun = false        // autopilot touched this run: don't record a best score
    private var aiHolding = false
    private var trailAt = 0.0
    var sound: (Sfx) -> Void = { _ in }
    var onBest: (Int) -> Void = { _ in }
    var onDeath: () -> Void = {}

    init(art: Art, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.art = art
        rng = RNG(s: seed)
    }

    var runSpeed: Double { power == .turbo ? min(K.maxSpeed * 1.6, speed * K.turboMul) : speed }
    /// Forward somersault angle in radians, 0 when not flipping.
    var flipAngle: Double {
        guard flipStart >= 0, !onGround else { return 0 }
        let k = (playTime - flipStart) / flipDur
        guard k < 1 else { return 0 }
        return 2 * .pi * (k < 0.5 ? 2 * k * k : 1 - pow(-2 * k + 2, 2) / 2)   // ease in-out
    }
    var invincible: Bool { power == .turbo || playTime < graceEnd }
    var powerLeft: Double { power == .none ? 0 : max(0, powerEnd - playTime) }
    /// Grows over a quarter second when the strawberry kicks in and shrinks back as it wears off.
    var dinoScale: Double {
        guard power == .big else { return 1 }
        let k = min(1, (playTime - powerStart) / 0.25, (powerEnd - playTime) / 0.25)
        return 1 + (K.bigScale - 1) * max(0, k)
    }

    // Input

    func press() {
        if paused { paused = false; return }
        switch phase {
        case .idle:
            start(); holding = true; jump()
        case .running:
            if power == .turbo { return }      // the juice box is driving
            holding = true
            if onGround { jump() } else { bufferedJump = clock }
        case .dead:
            if clock - deadAt > 0.45 { start(); holding = true; jump() }
        }
    }

    func release() {
        holding = false
        // During turbo the autopilot owns the jump: a stray tap must not cut it short.
        if phase == .running && !onGround && power != .turbo && vy > K.releaseV { vy = K.releaseV }
    }

    func pause() { if phase == .running { paused = true; holding = false } }

    private func start() {
        phase = .running; paused = false
        things = []; fx = []
        speed = K.startSpeed; score = 0; runPhase = 0; playTime = 0
        power = .none; graceEnd = -100
        gapLeft = max(120, worldW * 0.55)
        dinoY = 0; vy = 0; onGround = true; falling = false; flipStart = -1
        aiRun = autopilot
    }

    private func jump() {
        vy = power == .big ? K.jumpV * 0.75 : K.jumpV   // a giant only hops, so its head stays on screen
        onGround = false
        // Jumping a crate (and only a crate) earns a 360: spin if one lies within this jump's reach.
        let air = 2 * vy / K.gravity, reach = K.dinoX + 19 + runSpeed * air * 0.75
        if power == .none, things.contains(where: { $0.isBox && !$0.gone && $0.x + $0.width > K.dinoX + 4 && $0.x < reach }) {
            flipStart = playTime; flipDur = air * 0.85
        } else {
            flipStart = -1
        }
        sound(.jump)
    }

    // Simulation

    func step(_ dt: Double) {
        clock += dt
        if autopilot || (power == .turbo && phase == .running) { think() }
        if paused { return }

        if !onGround {
            vy -= K.gravity * dt
            dinoY += vy * dt
            if falling {
                dinoY = max(dinoY, -60)
            } else if dinoY <= 0 {
                if phase == .running && overOpenPit && pitsCanHurt {
                    fall()
                } else {
                    dinoY = 0; vy = 0; onGround = true
                    if phase == .running { landed() }
                }
            }
        }
        for i in fx.indices {
            fx[i].t += dt
            if case .dust = fx[i].look, phase == .running { fx[i].x -= runSpeed * 0.5 * dt }
        }
        fx.removeAll { $0.t >= $0.life }

        switch phase {
        case .idle: return
        case .dead:
            if !autopilot && clock - deadAt > 25 {
                phase = .idle; things = []; fx = []
                dinoY = 0; vy = 0; onGround = true; falling = false
            }
            return
        case .running: break
        }

        playTime += dt
        if power != .none && playTime >= powerEnd { endPower() }
        speed = min(K.maxSpeed, speed + K.accel * dt)
        let v = runSpeed
        let hundreds = Int(score) / 100
        score += v * dt / K.pxPerPoint
        if Int(score) / 100 > hundreds { flashAt = clock; sound(.point) }
        scroll += v * dt
        runPhase += dt * min(26, 8 + v / 20)

        for i in things.indices {
            things[i].x -= (v + things[i].extraSpeed) * dt
            things[i].t += dt
        }
        things.removeAll { $0.x + $0.width < -60 }
        gapLeft -= v * dt
        if gapLeft <= 0 { spawn() }
        openPits()
        if power == .turbo && onGround && playTime - trailAt > 0.05 {   // speed dust behind the feet
            trailAt = playTime
            fx.append(Effect(look: .dust, x: K.dinoX - 4, y: -4, life: 0.22))
        }
        collide()
        if phase == .running && onGround && overOpenPit && pitsCanHurt { fall() }
    }

    private func landed() {
        flipStart = -1
        fx.append(Effect(look: .dust, x: K.dinoX - 2, y: -4, life: 0.3))
        fx.append(Effect(look: .dust, x: K.dinoX + 8 * dinoScale, y: -4, life: 0.25))
        if clock - bufferedJump < 0.15 {
            bufferedJump = -100
            jump()
            if !holding { vy = 150 }
        }
    }

    private func spawn() {
        var options: [(Kind, Double)] = [(.spikes(1), 3), (.spikes(2), 2)]
        if score >= 100 { options.append((.box(rng.int(2)), 2)) }
        if score >= 150 { options.append((.pit(0, fire: score >= 300 && rng.unit() < 0.4), 1.2)) }
        if score >= 200 { options.append((.saw, 1.5)) }
        if score >= 250 { options.append((.spikes(3), 1.3)) }
        if score >= 350 {
            options.append((.bird(rng.int(2), high: true), 1.3))
            options.append((.bird(rng.int(2), high: false), 1.3))
        }
        var r = rng.unit() * options.reduce(0) { $0 + $1.1 }
        var kind = options[0].0
        for (k, w) in options { if r < w { kind = k; break }; r -= w }

        let v = runSpeed
        if case .pit(_, let fire) = kind {
            // Warning sign first, then the red pebble that marks where the ground will give way.
            // About 3/4 of a full jump wide at the normal (non-turbo) speed: a tap-hop won't clear it.
            let jump = speed * 2 * K.jumpV / K.gravity
            let w = Int(jump * rng.range(0.7, 0.78)), lead = max(130, v * 0.9)
            things.append(Thing(kind: .sign(fire: fire), x: worldW + 4))
            things.append(Thing(kind: .pit(w, fire: fire), x: worldW + 4 + lead))
            gapLeft = lead + Double(w) + v * rng.range(0.75, 1.3) + 26
            return
        }

        let thing = Thing(kind: kind, x: worldW + 4)
        things.append(thing)
        let gap = v * rng.range(0.75, 1.6) + 26
        gapLeft = thing.width + gap
        if !thing.isHighBird, rng.unit() < 0.22 {
            let p = rng.unit()
            var k = p < 0.5 ? Fruit.cherry : p < 0.66 ? Fruit.orange : p < 0.83 ? Fruit.strawberry : Fruit.juice
            if power != .none && (k == Fruit.strawberry || k == Fruit.juice) { k = Fruit.cherry }
            var f = Thing(kind: .fruit(k), x: worldW + 4 + thing.width + gap * rng.range(0.4, 0.6))
            f.y = rng.range(9, 22)
            things.append(f)
        }
    }

    var dinoFrame: Int {
        switch phase {
        case .idle: return Int(clock * 5) % 4
        case .dead:
            let seq = [13, 14, 15, 16, 14]
            return seq[min(Int((clock - deadAt) * 12), seq.count - 1)]
        case .running:
            if !onGround { return vy > 0 ? 6 : 9 }
            if power == .turbo { return Int(clock * 5) % 4 }   // on skates: glide in the standing pose
            return 4 + Int(runPhase) % 6
        }
    }

    func parts(_ t: Thing) -> [Part] {
        switch t.kind {
        case .spikes(let n):
            let f = art.spike
            return (0..<n).map { Part(frame: f, x: t.x + Double($0 * 15 - f.mask.padLeft), y: Double(-f.mask.padBottom)) }
        case .box(let v):
            let f = art.boxes[v]
            return [Part(frame: f, x: t.x - Double(f.mask.padLeft), y: Double(-f.mask.padBottom))]
        case .saw:
            return [Part(frame: art.saw[Int(t.t * 18) % 8], x: t.x, y: -22)]   // half buried, 16 px showing
        case .bird(let c, let high):
            let x = t.x - Double(art.birdPadLeft[c])
            if high {
                return [Part(frame: art.birds[c][Int(t.t * 9) % 5], x: x, y: K.highBirdBottom - Double(art.birdPadBottom[c]))]
            }
            let f = art.birds[c][2]   // wings level: a low glide
            return [Part(frame: f, x: x, y: K.lowBirdBottom - Double(f.mask.padBottom))]
        case .fruit(let k):
            let f = art.fruits[k][Int(t.t * 20) % 17]
            let f0 = art.fruits[k][0].mask
            return [Part(frame: f, x: t.x - Double(f0.padLeft), y: t.y - Double(f0.padBottom))]
        case .pit(let w, let fire):
            if !t.opened { return [Part(frame: art.pebble, x: t.x, y: 0)] }
            guard fire else { return [] }
            // Flames shoot up out of the hole, kept a few px in from both edges.
            let rise = min(1, (t.t - t.y) / 0.25), sink = -12 * (1 - rise)
            let n = max(1, (w - 16 - 7) / 6 + 1)
            return (0..<n).map { i in
                Part(frame: art.flames[(Int(t.t * 12) + i * 3) % 4], x: t.x + 8 + Double(i * 6), y: sink)
            }
        case .sign(let fire):
            return [Part(frame: art.signs[fire ? 1 : 0], x: t.x, y: 0, scale: 0.5)]
        }
    }

    /// Opaque bounds of a thing in world px, above the ground.
    func bounds(_ t: Thing) -> CGRect? {
        var r: CGRect?
        for p in parts(t) {
            let b = p.frame.mask.box
            let pr = CGRect(x: p.x + b.minX * p.scale, y: p.y + b.minY * p.scale, width: b.width * p.scale, height: b.height * p.scale)
            r = r.map { $0.union(pr) } ?? pr
        }
        guard let out = r, out.maxY > 0 else { return nil }
        return CGRect(x: out.minX, y: max(0, out.minY), width: out.width, height: out.maxY - max(0, out.minY))
    }

    /// The feet are over a pit that has caved in.
    var overOpenPit: Bool {
        things.contains { $0.isPit && $0.opened && $0.x <= K.dinoX + 7 && $0.x + $0.width >= K.dinoX + 16 }
    }
    private var pitsCanHurt: Bool { power != .big && !invincible }   // a giant strides across

    /// The ground gives way only once the dino is close: until then, the red pebble is the only cue.
    private func openPits() {
        let front = K.dinoX + 4 + 15 * dinoScale
        for i in things.indices where things[i].isPit && !things[i].opened && things[i].x <= front + runSpeed * K.pitOpenLead {
            things[i].opened = true
            things[i].y = things[i].t
            let x = things[i].x, w = things[i].width
            fx.append(Effect(look: .poof, x: x + w / 2 - 16, y: -16, life: 0.33))
            fx.append(Effect(look: .dust, x: x - 4, y: -4, life: 0.3))
            fx.append(Effect(look: .dust, x: x + w - 10, y: -4, life: 0.3))
            sound(things[i].isFirePit ? .fire : .crumble)
        }
    }

    private func fall() {
        falling = true; onGround = false; vy = min(vy, 0)
        die()
    }

    private func collide() {
        if power == .big { smash(); return }
        let i = dinoFrame
        let dx = Int(K.dinoX.rounded()), dy = Int((dinoY - 3).rounded())
        for n in things.indices where !things[n].gone && (things[n].isFruit || things[n].isSolid || things[n].isFirePit) {
            let fruit = things[n].isFruit
            let me = fruit ? art.dino[i].mask : art.dinoHit[i]
            for p in parts(things[n]) where overlaps(me, dx, dy, p.frame.mask, Int(p.x.rounded()), Int(p.y.rounded())) {
                if fruit { collect(n); break }
                if invincible {
                    if power == .turbo { turboBumps += 1; if !things[n].isPit { smashThing(n) } }
                    break
                }
                die(); return
            }
        }
    }

    /// Strawberry power: whatever the (scaled) dino touches is destroyed.
    private func smash() {
        let s = dinoScale
        let x0 = K.dinoX + 4 * s, x1 = K.dinoX + 20 * s, y0 = dinoY, y1 = dinoY + 17 * s
        for n in things.indices where !things[n].gone && (things[n].isFruit || things[n].isSolid) {
            guard let r = bounds(things[n]), r.minX < x1, r.maxX > x0, r.minY < y1, r.maxY > y0 else { continue }
            if things[n].isFruit { collect(n) } else { smashThing(n) }
        }
    }

    private func smashThing(_ n: Int) {
        things[n].gone = true
        score += K.smashBonus
        let r = bounds(things[n]) ?? CGRect(x: things[n].x, y: 0, width: things[n].width, height: 16)
        fx.append(Effect(look: .poof, x: r.midX - 16, y: r.minY - 6, life: 0.33))
        fx.append(Effect(look: .text("+10"), x: r.midX - 8, y: r.maxY + 2, life: 0.6))
        sound(.smash)
    }

    private func collect(_ n: Int) {
        things[n].gone = true
        score += K.fruitBonus
        let p = parts(things[n])[0]
        fx.append(Effect(look: .poof, x: p.x, y: p.y, life: 0.33))
        var label = "+50"
        if case .fruit(let k) = things[n].kind {
            if k == Fruit.strawberry { begin(.big); label = "BIG!" }
            if k == Fruit.juice { begin(.turbo); label = "TURBO!" }
        }
        fx.append(Effect(look: .text(label), x: things[n].x - 3, y: things[n].y + 16, life: label == "+50" ? 0.7 : 1.0))
        sound(label == "+50" ? .fruit : .power)
    }

    private func begin(_ p: Power) {
        let grown = power == .big && p == .big
        if power == .turbo { endTurboControl() }
        power = p
        powerStart = grown ? playTime - 1 : playTime   // a second strawberry extends without re-growing
        powerEnd = playTime + (p == .big ? K.bigTime : K.turboTime)
        if p == .turbo { holding = false; bufferedJump = -100 }
    }

    private func endPower() {
        if power == .turbo { endTurboControl() }
        power = .none
        graceEnd = playTime + K.grace     // a moment to get your bearings at normal speed and size
    }

    private func endTurboControl() {
        if !autopilot { aiHolding = false; holding = false }
    }

    private func die() {
        phase = .dead; deadAt = clock; holding = false; aiHolding = false; flipStart = -1
        power = .none
        sound(.hit)
        if !aiRun && Int(score) > best { best = Int(score); onBest(best) }
        onDeath()
    }

    /// Autopilot: plays the game itself (demo mode, the juice-box turbo, and the self-test's fairness check).
    private func think() {
        switch phase {
        case .idle: if autopilot { press(); release() }; return
        case .dead: if autopilot && clock - deadAt > 1.6 { press(); release() }; return
        case .running: break
        }
        if paused { return }
        if aiHolding && !onGround && vy < 30 { aiHolding = false; release() }
        guard onGround, power != .big else { return }    // a giant just walks through
        let body = K.dinoX + 4
        guard let next = things.filter({ !$0.gone && ($0.isSolid || $0.isPit) && !$0.isHighBird && $0.x + $0.width > body })
            .min(by: { $0.x < $1.x }) else { return }
        let rel = runSpeed + next.extraSpeed
        let travel = rel * 2 * K.jumpV / K.gravity
        let lead = max(2, (travel - next.width - 15) / 2)
        if next.x - (body + 15) <= lead { holding = true; jump(); aiHolding = true }
    }
}

// MARK: - Rendering (Core Animation: the GPU composites sprite layers; the CPU only moves them)

final class Scene {
    let art: Art
    let root = CALayer()
    private let backdrop = CALayer()           // shows the click-to-jump zone while hovered
    private let world = CALayer()
    private let groundBox = CALayer()          // ground line segments (gaps where pits have opened) + holes
    private var groundImg: CGImage?            // the full-width line, edge fade baked in
    private let thingBox = CALayer()           // clips at the ground so the saw sits half buried
    private let shadowL = CALayer(), dinoL = CALayer(), skateL = CALayer(), juiceL = CALayer(), hudL = CALayer(), msgL = CALayer()
    private var thingPool: [CALayer] = [], fxPool: [CALayer] = [], pebblePool: [CALayer] = []
    private var groundPool: [CALayer] = [], holePool: [CALayer] = []
    private var hudKey = "", msgKey = ""
    private var pebblesColored = 0
    private var textCache: [String: CGImage] = [:]
    private(set) var px: CGFloat = 0, backing: CGFloat = 0, size = CGSize.zero
    static let pebblePeriod = 700.0

    private let pebbles: [(x: Double, y: Double, w: Double)] = {
        var r = RNG(s: 7)
        return (0..<70).map { _ in (r.range(0, 698), r.unit() < 0.5 ? -2 : -3, r.unit() < 0.7 ? 1 : 2) }
    }()

    init(art: Art) {
        self.art = art
        backdrop.cornerRadius = 10
        backdrop.backgroundColor = CGColor(gray: 0, alpha: 0.08)
        backdrop.borderColor = CGColor(gray: 1, alpha: 0.22)
        backdrop.borderWidth = 1
        backdrop.isHidden = true
        thingBox.masksToBounds = true
        root.addSublayer(backdrop)
        root.addSublayer(world)
        world.addSublayer(groundBox)
        world.addSublayer(shadowL)
        world.addSublayer(thingBox)
        world.addSublayer(dinoL)
        world.addSublayer(skateL)
        world.addSublayer(juiceL)
        root.addSublayer(hudL)
        root.addSublayer(msgL)
        [shadowL, dinoL, skateL, juiceL, hudL, msgL].forEach(pixelate)
    }

    private func pixelate(_ l: CALayer) {
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.contentsGravity = .resize
    }
    private func snap(_ v: CGFloat) -> CGFloat { (v * backing).rounded() / backing }
    var tp: CGFloat { max(1, (px * backing / 2).rounded()) / backing }     // points per font pixel

    func layout(size: CGSize, px: CGFloat, backing: CGFloat) {
        guard size != self.size || px != self.px || backing != self.backing, size.width > 0 else { return }
        self.size = size; self.px = px; self.backing = backing
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        backdrop.frame = root.bounds.insetBy(dx: 0.5, dy: 0.5)
        world.frame = root.bounds
        let groundTop = snap(CGFloat(K.below) * px)
        thingBox.frame = CGRect(x: 0, y: groundTop, width: size.width, height: size.height - groundTop)
        groundBox.frame = root.bounds
        groundImg = groundImage()
        hudKey = ""; msgKey = ""; textCache = [:]
        CATransaction.commit()
    }

    /// Edge fade (0...1) at a point x: the world fades in on the right and out on the left.
    /// Per-layer opacity instead of a mask layer: masks cost WindowServer an offscreen pass every frame.
    func fade(_ x: CGFloat) -> Float {
        Float(max(0, min(1, x / (10 * px), (size.width - x) / (28 * px))))
    }

    /// The ground line: a light top edge over a mid-grey band reads on light and dark desktops.
    private func groundImage() -> CGImage {
        let b = backing, w = size.width, h = px
        let W = Int((w * b).rounded()), H = max(1, Int((h * b).rounded()))
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<W {
            let f = CGFloat(fade(CGFloat(x) / b))
            ctx.setFillColor(CGColor(gray: 0.38, alpha: 0.6 * f))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: H - 1))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.5 * f))
            ctx.fill(CGRect(x: x, y: H - 1, width: 1, height: 1))
        }
        return ctx.makeImage()!
    }

    /// World px -> layer frame (points), relative to `parentY` (0 for world, ground top for things).
    private func place(_ l: CALayer, _ img: CGImage, _ x: Double, _ y: Double, parentY: CGFloat = 0, scale: Double = 1) {
        if (l.contents as AnyObject?) !== img { l.contents = img }
        l.frame = CGRect(x: snap(CGFloat(x) * px), y: snap(CGFloat(y + K.below) * px) - parentY,
                         width: snap(CGFloat(Double(img.width) * scale) * px), height: snap(CGFloat(Double(img.height) * scale) * px))
    }

    private func pooled(_ pool: inout [CALayer], _ i: Int, in parent: CALayer) -> CALayer {
        if i == pool.count {
            let l = CALayer()
            pixelate(l)
            parent.addSublayer(l)
            pool.append(l)
        }
        pool[i].isHidden = false
        return pool[i]
    }

    func update(_ g: Game, hover: Bool, hint: String) {
        guard size.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        backdrop.isHidden = !hover

        // Ground line, cut where pits have opened; the holes show through the gaps.
        let pits = g.things.filter { $0.isPit && $0.opened }
        let gaps = pits.map { (snap(CGFloat($0.x) * px), snap(CGFloat($0.x + $0.width) * px)) }.sorted { $0.0 < $1.0 }
        var n = 0, from: CGFloat = 0
        func segment(_ a: CGFloat, _ b: CGFloat) {
            guard b > a, let img = groundImg else { return }
            let l = pooled(&groundPool, n, in: groundBox)
            if (l.contents as AnyObject?) !== img { l.contents = img }
            l.contentsRect = CGRect(x: a / size.width, y: 0, width: (b - a) / size.width, height: 1)
            l.frame = CGRect(x: a, y: thingBox.frame.minY - px, width: b - a, height: px)
            n += 1
        }
        for (a, b) in gaps { segment(from, min(a, size.width)); from = max(from, b) }
        segment(from, size.width)
        for i in n..<groundPool.count { groundPool[i].isHidden = true }
        n = 0
        for p in pits {
            let l = pooled(&holePool, n, in: groundBox)
            place(l, art.hole(Int(p.width), fire: p.isFirePit), p.x, -K.below)
            l.opacity = fade(l.frame.midX)
            n += 1
        }
        for i in n..<holePool.count { holePool[i].isHidden = true }

        // Pebbles under the ground line scroll with the world (tiny colour layers, no bitmaps).
        n = 0
        let period = Scene.pebblePeriod
        let shift = g.scroll.truncatingRemainder(dividingBy: period)
        for k in 0...Int(g.worldW / period) + 1 {
            for p in pebbles {
                var x = p.x - shift
                if x < 0 { x += period }
                x += Double(k) * period
                if x > g.worldW + 2 || pits.contains(where: { x + p.w > $0.x && x < $0.x + $0.width }) { continue }
                let l = pooled(&pebblePool, n, in: world)
                if n >= pebblesColored { l.backgroundColor = CGColor(gray: 0.45, alpha: 1); pebblesColored = n + 1 }
                l.frame = CGRect(x: snap(CGFloat(x) * px), y: CGFloat(p.y + K.below) * px, width: CGFloat(p.w) * px, height: px)
                l.opacity = 0.5 * fade(l.frame.midX)
                n += 1
            }
        }
        for i in n..<pebblePool.count { pebblePool[i].isHidden = true }

        let s = g.dinoScale
        place(shadowL, art.shadow, K.dinoX, -3 * s, scale: s)
        shadowL.opacity = Float(0.55 * max(0.2, 1 - g.dinoY / 45))
        shadowL.isHidden = g.falling || g.overOpenPit
        // Turbo: roller skates lift the dino onto its wheels, and it sips the juice box on the way.
        let skating = g.power == .turbo && g.phase == .running
        let frame = g.dinoFrame
        let bodyY = g.dinoY - 3 * s + (skating ? K.skateLift : 0)
        dinoL.setAffineTransform(.identity)
        place(dinoL, art.dino[frame].image, K.dinoX, bodyY, scale: s)
        if g.flipAngle != 0 { dinoL.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(g.flipAngle))) }   // clockwise = forward
        skateL.isHidden = !skating; juiceL.isHidden = !skating
        if skating {
            place(skateL, art.skates[Int(g.playTime * 14) % 2], K.dinoX + 5, g.dinoY)
            let bob = Double(art.dino[frame].mask.box.maxY - art.dino[0].mask.box.maxY)   // follow the head
            place(juiceL, art.juiceHeld[Int(g.playTime * 6) % 3], K.dinoX + 16, bodyY + 5 + bob)
        }
        // Blink while a power is about to wear off and during the grace moment after it.
        let ending = (g.power != .none && g.powerLeft < 1.5) || (g.phase == .running && g.playTime < g.graceEnd)
        dinoL.opacity = ending && Int(g.playTime * 10) % 2 == 1 ? 0.35 : 1
        skateL.opacity = dinoL.opacity; juiceL.opacity = dinoL.opacity

        let groundTop = thingBox.frame.minY
        n = 0
        for t in g.things where !t.gone {
            for p in g.parts(t) {
                let l = pooled(&thingPool, n, in: thingBox)
                place(l, p.frame.image, p.x, p.y, parentY: groundTop, scale: p.scale)
                l.opacity = fade(l.frame.midX)
                n += 1
            }
        }
        for i in n..<thingPool.count { thingPool[i].isHidden = true }

        n = 0
        for e in g.fx {
            let l = pooled(&fxPool, n, in: world)
            n += 1
            let a = Float(1 - e.t / e.life)
            switch e.look {
            case .dust: place(l, art.dust, e.x, e.y); l.opacity = 0.85 * a * fade(l.frame.midX)
            case .poof: place(l, art.poof[min(5, Int(e.t * 18))], e.x, e.y); l.opacity = fade(l.frame.midX)
            case .text(let s):
                let img = cachedText(s)
                if (l.contents as AnyObject?) !== img { l.contents = img }
                l.frame = textFrame(img, inkX: CGFloat(e.x) * px, inkY: snap(CGFloat(e.y + K.below + e.t * 14) * px))
                l.opacity = a
            }
        }
        for i in n..<fxPool.count { fxPool[i].isHidden = true }

        // HUD: best + score, top right. The score blinks for a second at every 100.
        var hud = g.power == .big ? "BIG " : g.power == .turbo ? "TURBO " : ""
        if g.power != .none { hud += "\(Int(g.powerLeft.rounded(.up)))  " }
        hud += g.best > 0 ? "HI " + String(format: "%05d", g.best) : ""
        if g.phase != .idle { hud += (hud.isEmpty || hud.hasSuffix(" ") ? "" : "  ") + String(format: "%05d", Int(g.score)) }
        if hud != hudKey {
            hudKey = hud
            if hud.isEmpty { hudL.contents = nil } else {
                let img = textImage(hud)
                hudL.contents = img
                hudL.frame = textFrame(img, inkX: size.width - 8 * tp - width(hud), inkY: size.height - 13 * tp)
            }
        }
        hudL.isHidden = g.clock - g.flashAt < 1.0 && Int((g.clock - g.flashAt) * 8) % 2 == 1
        hudL.opacity = 0.95

        var msg = ""
        if g.paused { msg = "PAUSED" } else if g.phase == .dead { msg = "GAME OVER" } else if g.phase == .idle { msg = hint }
        if msg != msgKey {
            msgKey = msg
            if msg.isEmpty { msgL.contents = nil } else {
                let img = textImage(msg)
                msgL.contents = img
                msgL.frame = textFrame(img, inkX: ((size.width - width(msg)) / 2).rounded(), inkY: CGFloat(28 + K.below) * px)
            }
        }
        msgL.opacity = g.phase == .idle && !g.paused ? Float(0.6 + 0.3 * sin(g.clock * 3)) : 1
    }

    // Pixel-font text, baked into small bitmaps only when the string changes.

    func width(_ str: String) -> CGFloat {
        CGFloat(str.reduce(0) { $0 + ($1 == " " ? 4 : 7) } - 1) * tp
    }

    private func cachedText(_ s: String) -> CGImage {
        if let c = textCache[s] { return c }
        let img = textImage(s)
        textCache[s] = img
        return img
    }

    /// Frame for a text bitmap so its ink starts at (inkX, inkY). Bitmaps carry a 2 font-px margin.
    private func textFrame(_ img: CGImage, inkX: CGFloat, inkY: CGFloat) -> CGRect {
        CGRect(x: inkX - 2 * tp, y: inkY - 2 * tp, width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing)
    }

    /// White pixel font with a 1 px black outline, so it reads over any window.
    private func textImage(_ str: String) -> CGImage {
        let t = tp, b = backing
        let w = width(str) + 4 * t, h = 12 * t
        let ctx = CGContext(data: nil, width: Int((w * b).rounded()), height: Int((h * b).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: b, y: b)
        ctx.interpolationQuality = .none
        for pass in 0..<2 {
            var cx = t             // ink starts 1 px into each 8x10 glyph cell
            for ch in str {
                if ch == " " { cx += 4 * t; continue }
                if let g = art.glyphs[ch] {
                    let r = CGRect(x: cx, y: t, width: 8 * t, height: 10 * t)
                    if pass == 0 {
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            ctx.draw(g.black, in: r.offsetBy(dx: CGFloat(dx) * t, dy: CGFloat(dy) * t))
                        }
                    } else {
                        ctx.draw(g.white, in: r)
                    }
                }
                cx += 7 * t
            }
        }
        return ctx.makeImage()!
    }
}

// MARK: - Sound (synthesised square-wave blips, no files)

final class Sounds {
    var enabled = true
    private var players: [Sfx: AVAudioPlayer] = [:]
    private let rate = 22050.0

    init() {
        players[.jump] = make(sweep(380, 760, 0.07))
        players[.point] = make(tone(880, 0.06) + tone(1320, 0.11))
        players[.fruit] = make(tone(990, 0.04) + tone(1320, 0.04) + tone(1760, 0.08))
        players[.hit] = make(sweep(320, 70, 0.28, noise: 0.35))
        players[.power] = make(tone(660, 0.05) + tone(880, 0.05) + tone(1100, 0.05) + tone(1320, 0.05) + tone(1760, 0.12))
        players[.smash] = make(sweep(220, 60, 0.12, noise: 0.6))
        players[.crumble] = make(sweep(150, 45, 0.22, noise: 0.75))
        players[.fire] = make(sweep(90, 260, 0.3, noise: 0.85))
    }

    func play(_ s: Sfx) {
        guard enabled, let p = players[s] else { return }
        p.currentTime = 0
        p.play()
    }

    private func tone(_ f: Double, _ d: Double) -> [Float] { sweep(f, f, d) }

    private func sweep(_ f0: Double, _ f1: Double, _ d: Double, noise: Double = 0) -> [Float] {
        let n = Int(d * rate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        var r = RNG(s: 99)
        for i in 0..<n {
            let t = Double(i) / Double(n)
            phase += (f0 + (f1 - f0) * t) / rate
            var v = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1.0 : -1.0
            if noise > 0 { v = v * (1 - noise) + (r.unit() * 2 - 1) * noise }
            let env = min(1, Double(i) / (0.004 * rate)) * (1 - t)
            out[i] = Float(v * env * 0.22)
        }
        return out
    }

    private func make(_ samples: [Float]) -> AVAudioPlayer? {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        let p = try? AVAudioPlayer(data: d)
        p?.volume = 0.5
        p?.prepareToPlay()
        return p
    }
}

// MARK: - Settings

enum Prefs {
    static let d = UserDefaults.standard
    static var character: String { get { d.string(forKey: "character") ?? "vita" } set { d.set(newValue, forKey: "character") } }
    static var scale: Double { get { d.object(forKey: "scale") as? Double ?? 2 } set { d.set(newValue, forKey: "scale") } }
    static var width: String { get { d.string(forKey: "width") ?? "720" } set { d.set(newValue, forKey: "width") } }
    static var sound: Bool { get { d.object(forKey: "sound") as? Bool ?? true } set { d.set(newValue, forKey: "sound") } }
    static var autopilot: Bool { get { d.bool(forKey: "autopilot") } set { d.set(newValue, forKey: "autopilot") } }
    static var hidden: Bool { get { d.bool(forKey: "hidden") } set { d.set(newValue, forKey: "hidden") } }
    static var best: Int { get { d.integer(forKey: "best") } set { d.set(newValue, forKey: "best") } }
    static var askedInput: Bool { get { d.bool(forKey: "askedInputMonitoring") } set { d.set(newValue, forKey: "askedInputMonitoring") } }
}

// MARK: - Window

final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }    // clicks never steal focus from the app you're working in
    override var canBecomeMain: Bool { false }
}

final class GameView: NSView {
    weak var controller: Controller?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouse(down: true) }
    override func mouseUp(with event: NSEvent) { controller?.mouse(down: false) }
    override func rightMouseDown(with event: NSEvent) { controller?.popMenu(event, in: self) }
}

// MARK: - Global input (no focus needed)

var controller: Controller!
var eventTap: CFMachPort?
var hotKeyRef: EventHotKeyRef?

/// Right Option = jump, from any app. Listen-only tap: needs Input Monitoring, never blocks the key.
func startRightOptionTap() -> Bool {
    if eventTap != nil { return true }
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        } else if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_RightOption) {
            let down = event.flags.rawValue & 0x40 != 0      // NX_DEVICERALTKEYMASK
            DispatchQueue.main.async { controller.key(down: down) }
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { return false }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

/// ⌃⌥Space = jump. Carbon hot keys need no permission.
func registerHotKey() -> Bool {
    var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                 EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        DispatchQueue.main.async { controller.key(down: down) }
        return noErr
    }, 2, &specs, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x444B_4F53), id: 1)   // 'DKOS'
    return RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                               GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
}

/// The Dock's icon row, in Cocoa screen coordinates. Needs Accessibility; nil otherwise.
func dockIconFrame() -> CGRect? {
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
          let list = kids as? [AXUIElement] else { return nil }
    for el in list {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        guard (role as? String) == kAXListRole else { continue }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: primaryH - p.y - sz.height, width: sz.width, height: sz.height)
    }
    return nil
}

// MARK: - App

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let art = Art(character: Prefs.character)
    lazy var game = Game(art: art)
    lazy var scene = Scene(art: art)
    let sounds = Sounds()
    var panel: StripPanel!
    var view: GameView!
    var statusItem: NSStatusItem!
    var link: CADisplayLink?
    var lastTick = 0.0, lastTimestamp = 0.0
    var hover = false, mouseHolding = false
    var tapOn = false, hotKeyOn = false
    var currentRate: Float = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        sounds.enabled = Prefs.sound
        game.best = Prefs.best
        game.autopilot = Prefs.autopilot
        game.sound = { [weak self] s in if self?.game.autopilot == false { self?.sounds.play(s) } }
        game.onBest = { Prefs.best = $0 }

        panel = StripPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 112),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating                  // over windows, under the Dock (magnified icons win)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]   // not on full-screen spaces
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        view = GameView(frame: panel.contentLayoutRect)
        view.controller = self
        view.layer = scene.root          // layer-hosting: sprites are CALayers composited on the GPU
        view.wantsLayer = true
        panel.contentView = view

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuIcon()
        statusItem.button?.toolTip = "Dockosaur"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.autosaveName = "DockosaurStatusItem"

        hotKeyOn = registerHotKey()
        setupInputMonitoring(prompt: !Prefs.askedInput && !CommandLine.arguments.contains("--no-prompt"))

        layout()
        if !Prefs.hidden { panel.orderFrontRegardless() }
        startLink()

        // Housekeeping every 2 s: follow Dock changes, pick up a fresh Input Monitoring grant, revive a stalled link.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.layout()
            if !self.tapOn, CGPreflightListenEventAccess() { self.tapOn = startRightOptionTap() }
            if let t = eventTap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
            if !Prefs.hidden, CACurrentMediaTime() - self.lastTick > 1.5 { self.startLink() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.game.pause() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.game.pause() }
    }

    // Input

    func key(down: Bool) { if Prefs.hidden { return }; down ? press() : game.release() }
    func mouse(down: Bool) { mouseHolding = down; down ? press() : game.release() }
    private func press() {
        if game.holding { return }      // ignore key auto-repeat
        game.press()
        updateRate()
    }

    func setupInputMonitoring(prompt: Bool) {
        if CGPreflightListenEventAccess() { tapOn = startRightOptionTap(); return }
        if prompt {
            Prefs.askedInput = true
            if !CGRequestListenEventAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
        }
    }

    // Frame loop

    func startLink() {
        link?.invalidate()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
        currentRate = 0
        lastTick = CACurrentMediaTime()
        updateRate()
    }

    func updateRate() {
        // Full rate only while something moves; the idle dino breathes at 15 fps to save battery.
        let busy = (game.phase == .running && !game.paused) || !game.fx.isEmpty
            || (game.phase == .dead && game.clock - game.deadAt < 1)
        let want: Float = busy ? 60 : 15
        guard want != currentRate, let link else { return }
        currentRate = want
        link.preferredFrameRateRange = want > 30 ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                                                 : CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
    }

    @objc func tick(_ l: CADisplayLink) {
        lastTick = CACurrentMediaTime()
        var dt = lastTimestamp == 0 ? 1.0 / 60 : l.timestamp - lastTimestamp
        lastTimestamp = l.timestamp
        dt = min(max(dt, 0), 0.1)
        while dt > 0 {          // fixed small sub-steps keep collisions honest at low frame rates
            let h = min(dt, 1.0 / 120)
            game.step(h)
            dt -= h
        }
        let inside = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        if inside != hover {
            hover = inside
            panel.ignoresMouseEvents = !inside
            if !inside && mouseHolding { mouse(down: false) }
        }
        updateRate()
        render()
    }

    func render() {
        scene.layout(size: view.bounds.size, px: CGFloat(Prefs.scale), backing: panel.backingScaleFactor)
        scene.update(game, hover: hover,
                     hint: tapOn ? "TAP RIGHT OPTION TO PLAY" : hotKeyOn ? "CLICK OR CTRL+OPT+SPACE" : "CLICK TO PLAY")
    }

    // Placement: centred above the Dock, ground on the Dock's top edge.

    func layout() {
        guard let panel else { return }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 1 }) ?? screens.first else { return }
        let s = CGFloat(Prefs.scale)
        let vf = screen.visibleFrame, f = screen.frame
        let height = CGFloat(K.below + K.above) * s
        var width: CGFloat = 720, midX = vf.midX
        switch Prefs.width {
        case "dock":
            if let d = dockIconFrame(), screen.frame.intersects(d) { width = d.width; midX = d.midX }
        case "full": width = vf.width
        default: width = CGFloat(Double(Prefs.width) ?? 720)
        }
        width = min(max(width, 480), vf.width)
        width = (width / s).rounded(.down) * s
        let groundY = vf.minY > f.minY + 1 ? vf.minY : f.minY + 2
        var x = (midX - width / 2).rounded()
        x = min(max(x, vf.minX), vf.maxX - width)
        let frame = NSRect(x: x, y: (groundY - CGFloat(K.below) * s).rounded(), width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        game.worldW = Double(width / s)
    }

    // Menu bar

    func menuIcon() -> NSImage {
        let f = art.dino[0].image.cropping(to: CGRect(x: 3, y: 3, width: 18, height: 19))!
        let img = NSImage(size: NSSize(width: 18, height: 19), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(f, in: r)
            return true
        }
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: game.best > 0 ? "Dockosaur · best \(game.best)" : "Dockosaur", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        if game.phase == .running {
            menu.addItem(item(game.paused ? "Resume" : "Pause", #selector(togglePause)))
        } else {
            menu.addItem(item("New Game", #selector(newGame)))
        }
        menu.addItem(.separator())

        let controls = NSMenuItem(title: "Jump", action: nil, keyEquivalent: "")
        controls.isEnabled = false
        menu.addItem(controls)
        if tapOn {
            menu.addItem(info("    Right ⌥ (tap, hold for higher)"))
        } else {
            menu.addItem(item("    Enable Right ⌥ to Jump…", #selector(enableRightOption)))
        }
        if hotKeyOn { menu.addItem(info("    ⌃⌥Space")) }
        menu.addItem(info("    Click the game strip"))
        menu.addItem(.separator())

        menu.addItem(submenu("Dino", characters.map { ($0.name, $0.id) }, current: Prefs.character, #selector(pickCharacter(_:))))
        menu.addItem(submenu("Size", [("Small", "1.5"), ("Medium", "2.0"), ("Large", "3.0")],
                             current: String(format: "%.1f", Prefs.scale), #selector(pickScale(_:))))
        var widths: [(String, String)] = [("Narrow", "480"), ("Medium", "720"), ("Wide", "960"), ("Full Width", "full")]
        widths.insert((AXIsProcessTrusted() ? "Match Dock" : "Match Dock (needs Accessibility)…", "dock"), at: 0)
        menu.addItem(submenu("Width", widths, current: Prefs.width, #selector(pickWidth(_:))))
        menu.addItem(toggle("Sound", Prefs.sound, #selector(toggleSound)))
        menu.addItem(toggle("Autopilot (plays itself)", Prefs.autopilot, #selector(toggleAutopilot)))
        menu.addItem(.separator())
        menu.addItem(toggle("Show Game", !Prefs.hidden, #selector(toggleHidden)))
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(item("Reset Best Score", #selector(resetBest)))
        menu.addItem(item("About Dockosaur…", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dockosaur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func popMenu(_ event: NSEvent, in view: NSView) {
        guard let menu = statusItem.menu else { return }
        menuNeedsUpdate(menu)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }
    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
    private func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = item(title, sel)
        i.state = on ? .on : .off
        return i
    }
    private func submenu(_ title: String, _ options: [(String, String)], current: String, _ sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, value) in options {
            let i = item(name, sel)
            i.representedObject = value
            i.state = value == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc func togglePause() { if game.paused { game.paused = false } else { game.pause() }; updateRate() }
    @objc func newGame() { if game.phase == .dead { game.deadAt = -100 }; game.press(); game.release(); updateRate() }
    @objc func enableRightOption() {
        setupInputMonitoring(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func pickCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.character = id
        art.setCharacter(id)
        statusItem.button?.image = menuIcon()
        render()
    }
    @objc func pickScale(_ sender: NSMenuItem) {
        guard let v = (sender.representedObject as? String).flatMap(Double.init) else { return }
        Prefs.scale = v
        layout()
    }
    @objc func pickWidth(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        Prefs.width = v
        if v == "dock" && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        layout()
    }
    @objc func toggleSound() { Prefs.sound.toggle(); sounds.enabled = Prefs.sound }
    @objc func toggleAutopilot() { Prefs.autopilot.toggle(); game.autopilot = Prefs.autopilot; updateRate() }
    @objc func toggleHidden() {
        Prefs.hidden.toggle()
        if Prefs.hidden { game.pause(); panel.orderOut(nil); link?.isPaused = true }
        else { layout(); panel.orderFrontRegardless(); link?.isPaused = false; startLink() }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Dockosaur: launch at login failed: \(error)")
        }
    }
    @objc func resetBest() { game.best = 0; Prefs.best = 0 }
    @objc func about() {
        let a = NSAlert()
        a.messageText = "Dockosaur"
        a.informativeText = """
        An endless runner that lives on top of your Dock.
        Jump with Right ⌥, ⌃⌥Space, or a click. Hold for a higher jump.
        Stay low under high-flying pterodactyls. Jump at the red pebble after a PIT AHEAD sign.
        Strawberry: grow big and smash everything. Juice box: turbo on roller skates, the dino drives itself.

        Dino sprites: Arks (@ArksDigital), CC BY 4.0, arks.itch.io/dino-characters
        Spikes, crates, saw, fruit, dust & font: Pixel Frog, CC0, pixelfrog-assets.itch.io
        Pterodactyls, sign, pebble, juice box and skates: drawn for Dockosaur
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Offline tools: --snapshot and --selftest

func snapshot(_ args: [String]) {
    func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let out = arg("--snapshot")!
    let seconds = Double(arg("--seconds") ?? "8") ?? 8
    let scale = CGFloat(Double(arg("--scale") ?? "2") ?? 2)
    let widthPt = CGFloat(Double(arg("--width") ?? "720") ?? 720)
    let art = Art(character: arg("--dino") ?? "vita")
    let g = Game(art: art, seed: UInt64(arg("--seed") ?? "3") ?? 3)
    g.best = Int(arg("--best") ?? "0") ?? 0
    g.worldW = Double(widthPt / scale)
    if arg("--phase") != "idle" {
        g.autopilot = true
        if let s = arg("--score").flatMap(Double.init) { g.press(); g.release(); g.score = s }
        var t = 0.0
        while t < seconds { g.step(1.0 / 120); t += 1.0 / 120 }
        if let pw = arg("--power") {   // eat a power fruit, then run a little: --power big|turbo
            g.things.append(Thing(kind: .fruit(pw == "big" ? Fruit.strawberry : Fruit.juice), x: K.dinoX + 6, y: 8))
            for _ in 0..<60 { g.step(1.0 / 120) }
            if args.contains("--clear") { for _ in 0..<45 { g.things = []; g.step(1.0 / 120) } }   // land and cruise
        }
        if args.contains("--flip") {   // mid-somersault over a crate
            g.autopilot = false
            g.things = [Thing(kind: .box(0), x: K.dinoX + 2)]
            g.dinoY = 26; g.onGround = false; g.vy = 0
            g.flipStart = g.playTime - 0.18; g.flipDur = 0.5
        }
        if args.contains("--pit") {    // a staged pit scene: open pit under a jumping dino, sign + pebble ahead
            g.autopilot = false
            var open = Thing(kind: .pit(70, fire: args.contains("--fire")), x: K.dinoX - 30); open.opened = true; open.t = 1
            g.things = [open, Thing(kind: .bird(0, high: true), x: 70), Thing(kind: .bird(1, high: false), x: 125),
                        Thing(kind: .sign(fire: args.contains("--fire")), x: g.worldW - 150), Thing(kind: .pit(70, fire: false), x: g.worldW - 40),
                        Thing(kind: .fruit(Fruit.juice), x: g.worldW - 75, y: 14)]
            g.dinoY = 22; g.onGround = false; g.vy = 0
        }
        if arg("--phase") == "dead" { g.autopilot = false; g.things.removeAll(); g.paused = false
            // run into a wall of spikes to show the game-over screen
            g.things.append(Thing(kind: .spikes(3), x: K.dinoX + 6)); g.step(1.0 / 120); g.step(0.5) }
    } else {
        g.step(seconds)
    }
    let b: CGFloat = 2
    let size = CGSize(width: widthPt, height: CGFloat(K.below + K.above) * scale + (args.contains("--dock") ? 40 : 0))
    let ctx = CGContext(data: nil, width: Int(size.width * b), height: Int(size.height * b), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: b, y: b)
    switch arg("--bg") ?? "dark" {
    case "light": ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
    case "none": break
    default: ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
    }
    if args.contains("--dock") {   // fake Dock band under the strip for a context shot
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.16))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 4, width: size.width - 40, height: 32), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.translateBy(x: 0, y: 40 - CGFloat(K.below) * scale)
    }
    // Same layer tree as the live app, rendered in software.
    let scene = Scene(art: art)
    scene.layout(size: CGSize(width: widthPt, height: CGFloat(K.below + K.above) * scale), px: scale, backing: b)
    scene.update(g, hover: args.contains("--hover"), hint: "TAP RIGHT OPTION TO PLAY")
    ctx.interpolationQuality = .none
    scene.root.render(in: ctx)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out)  phase=\(g.phase) score=\(Int(g.score)) things=\(g.things.count)")
}

/// Records the README demo: a scripted reel through every feature, played by the autopilot and rendered with
/// the same layer tree as the live app.  Dockosaur --record docs/demo.gif [--from 0 --to 28.5 --fps 15]
func record(_ args: [String]) {
    func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let out = arg("--record")!
    let from = Double(arg("--from") ?? "0") ?? 0, to = Double(arg("--to") ?? "28.5") ?? 28.5
    let fps = Double(arg("--fps") ?? "15") ?? 15
    let scale: CGFloat = 2, widthPt: CGFloat = 640
    let art = Art(character: "vita")
    let g = Game(art: art, seed: 11)
    g.worldW = Double(widthPt / scale)
    g.best = 1240
    g.autopilot = true
    g.step(1.0 / 120)                    // autopilot starts the run
    g.score = 420; g.speed = 175

    // (time, what) — each thing enters at the right edge and reaches the dino about 1.6 s later.
    func enter(_ k: Kind, y: Double = 0) { var t = Thing(kind: k, x: g.worldW + 4); t.y = y; g.things.append(t) }
    func pit(fire: Bool) {
        let jump = g.speed * 2 * K.jumpV / K.gravity, lead = max(130, g.runSpeed * 0.9)
        enter(.sign(fire: fire))
        g.things.append(Thing(kind: .pit(Int(jump * 0.72), fire: fire), x: g.worldW + 4 + lead))
    }
    var script: [(Double, () -> Void)] = [
        (0.3, { enter(.box(0)) }),                               // 360 somersault over a crate
        (2.1, { enter(.bird(0, high: false)) }),                 // jump a low pterodactyl
        (3.6, { enter(.bird(1, high: true)) }),                  // duck under a high one
        (4.8, { enter(.fruit(Fruit.cherry), y: 8) }),            // +50
        (5.8, { enter(.fruit(Fruit.strawberry), y: 8) }),        // BIG
        (7.0, { enter(.spikes(2)) }), (7.9, { enter(.saw) }), (8.8, { enter(.bird(0, high: true)) }), (9.7, { enter(.box(1)) }),
        (12.6, { enter(.fruit(Fruit.juice), y: 8) }),            // TURBO: skates + juice box
        (14.6, { enter(.spikes(1)) }), (15.3, { enter(.box(0)) }), (16.0, { enter(.bird(1, high: false)) }),
        (19.4, { pit(fire: false) }),                            // PIT AHEAD + red pebble
        (23.0, { pit(fire: true) }),                             // FIRE PIT AHEAD
    ]
    let scene = Scene(art: art)
    let b: CGFloat = 1
    let size = CGSize(width: widthPt, height: CGFloat(K.below + K.above) * scale + 40)
    scene.layout(size: CGSize(width: widthPt, height: CGFloat(K.below + K.above) * scale), px: scale, backing: b)
    var images: [CGImage] = []
    var t = 0.0, deaths = 0
    g.onDeath = { deaths += 1 }
    while t < to {
        while let next = script.first, next.0 <= t { next.1(); script.removeFirst() }
        g.gapLeft = 1e9                  // only scripted things this time
        for _ in 0..<Int((120 / fps).rounded()) { g.step(1.0 / 120); t += 1.0 / 120 }   // whole sim steps per frame
        guard t >= from else { continue }
        let ctx = CGContext(data: nil, width: Int(size.width * b), height: Int(size.height * b), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: b, y: b)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.16))       // the Dock under the strip
        ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 4, width: size.width - 40, height: 32), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.translateBy(x: 0, y: 40 - CGFloat(K.below) * scale)
        scene.update(g, hover: false, hint: "")
        ctx.interpolationQuality = .none
        scene.root.render(in: ctx)
        images.append(ctx.makeImage()!)
    }
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "com.compuserve.gif" as CFString, images.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
    for img in images { CGImageDestinationAddImage(dest, img, frameProps) }
    let ok = CGImageDestinationFinalize(dest)
    print("\(ok ? "wrote" : "FAILED to write") \(out): \(images.count) frames, deaths \(deaths), score \(Int(g.score))")
}

func selftest() -> Int32 {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } }
    let art = Art(character: "vita")
    for c in characters { art.setCharacter(c.id); check(art.dino.count == 24 && !art.dino[4].mask.isEmpty, "dino \(c.id) frames") }
    art.setCharacter("vita")
    check(art.dino[4...9].map(\.mask.padBottom).min() == 3 && art.dino[4].mask.padLeft == 4, "dino feet/left padding is 3/4 px")
    check(art.saw.count == 8 && art.birds.allSatisfy { $0.count == 5 && !$0[2].mask.isEmpty }, "saw + bird frames")
    check(art.fruits.allSatisfy { $0.count == 17 }, "fruit frames")
    check(art.juiceHeld.count == 3 && art.skates.count == 2 && !art.fruits[Fruit.juice][0].mask.isEmpty, "juice box + skates")
    for ch in "HI 0123456789 GAME OVER PAUSED TAP RIGHT OPTION TO PLAY CLICK OR CTRL+OPT+SPACE +50 +10 BIG! TURBO! FIRE PIT AHEAD" where ch != " " {
        check(art.glyphs[ch] != nil, "glyph \(ch)")
    }

    // Physics: a full jump clears the tallest ground hazard (crate, 20 px) and a short hop is lower.
    let g = Game(art: art, seed: 1)
    g.press()
    var apex = 0.0
    for _ in 0..<240 { g.step(1.0 / 120); apex = max(apex, g.dinoY) }
    check(apex > 30 && apex < 36, "full jump apex \(apex)")
    let h = Game(art: art, seed: 1)
    h.press(); h.step(0.05); h.release()
    var hop = 0.0
    for _ in 0..<240 { h.step(1.0 / 120); hop = max(hop, h.dinoY) }
    check(hop < 20 && hop > 10, "short hop apex \(hop)")

    // A standing dino fits under a high hawk; a jumping one doesn't.
    let b = Game(art: art, seed: 1)
    b.press(); b.release(); b.step(1)   // start running, land
    b.things = [Thing(kind: .bird(1, high: true), x: K.dinoX + 4)]
    for _ in 0..<12 { b.things[0].x = K.dinoX + 4; b.step(1.0 / 120) }
    check(b.phase == .running, "dino passes under a high hawk")

    // Strawberry: the dino grows and smashes what it runs into.
    let s = Game(art: art, seed: 1)
    s.press(); s.release(); s.step(1)
    s.things = [Thing(kind: .fruit(Fruit.strawberry), x: K.dinoX + 6, y: 8)]
    s.step(1.0 / 120)
    check(s.power == .big, "strawberry makes the dino big")
    for _ in 0..<40 { s.step(1.0 / 120) }
    check(s.dinoScale > 1.7, "big dino grows to full size (\(s.dinoScale))")
    s.things = [Thing(kind: .box(0), x: K.dinoX + 40), Thing(kind: .bird(0, high: true), x: K.dinoX + 90)]
    for _ in 0..<90 { s.step(1.0 / 120) }
    check(s.phase == .running && s.things.allSatisfy(\.gone), "big dino smashes a crate and a pterodactyl")
    for _ in 0..<(7 * 120) { s.things = []; s.step(1.0 / 120) }
    check(s.power == .none && s.dinoScale == 1, "big wears off")

    // Juice box: turbo speed, and the player's presses are ignored while it drives.
    let a = Game(art: art, seed: 1)
    a.press(); a.release(); a.step(1)
    a.things = [Thing(kind: .fruit(Fruit.juice), x: K.dinoX + 6, y: 8)]
    a.step(1.0 / 120)
    check(a.power == .turbo && a.runSpeed > a.speed * 1.5, "juice box gives turbo")
    a.things = []; a.press()
    check(a.onGround, "presses are ignored during turbo")
    a.things = [Thing(kind: .spikes(2), x: K.dinoX + 60)]
    for i in 0..<120 { if i % 6 == 0 { a.press() }; if i % 6 == 2 { a.release() }; a.step(1.0 / 120) }
    check(a.turboBumps == 0, "tapping during turbo doesn't cut the autopilot's jump (\(a.turboBumps) bumps)")

    // Somersault: jumping a crate flips the dino, jumping spikes doesn't.
    let c = Game(art: art, seed: 1)
    c.press(); c.release(); c.step(1)
    c.things = [Thing(kind: .box(0), x: K.dinoX + 40)]
    c.press(); c.step(0.15)
    check(c.flipAngle > 0, "jumping a crate starts a somersault")
    let sp = Game(art: art, seed: 1)
    sp.press(); sp.release(); sp.step(1)
    sp.things = [Thing(kind: .spikes(2), x: K.dinoX + 40)]
    sp.press(); sp.step(0.15)
    check(sp.flipAngle == 0, "no somersault over spikes")

    // Pit: closed while far away (only the pebble shows), opens near the dino, and standing over it is fatal.
    let p = Game(art: art, seed: 1)
    p.press(); p.release(); p.step(1)
    p.things = [Thing(kind: .pit(70, fire: false), x: 160)]
    p.step(1.0 / 120)
    check(!p.things[0].opened && p.parts(p.things[0]).count == 1, "pit hidden behind its pebble at a distance")
    for _ in 0..<120 { p.step(1.0 / 120) }
    check(p.things.first?.opened == true && p.phase == .dead && p.falling, "running onto a pit drops the dino")
    let jumpLen = K.startSpeed * 2 * K.jumpV / K.gravity
    for fire in [false, true] {
        let q = Game(art: art, seed: 1)
        q.press(); q.release(); q.step(1)
        q.things = [Thing(kind: .pit(Int(jumpLen * 0.78), fire: fire), x: 160)]
        q.autopilot = true
        for _ in 0..<240 { q.step(1.0 / 120) }
        check(q.phase == .running, "a full jump clears a \(fire ? "fire " : "")pit \(Int(jumpLen * 0.78)) px wide")
    }
    // A short hop into a fire pit gets burned.
    let f = Game(art: art, seed: 1)
    f.press(); f.release(); f.step(1)
    var fp = Thing(kind: .pit(70, fire: true), x: K.dinoX - 20); fp.opened = true; fp.t = 1
    f.things = [fp]
    f.dinoY = 4; f.vy = 0; f.onGround = false
    for _ in 0..<6 { f.step(1.0 / 120) }
    check(f.phase == .dead && !f.falling, "flames burn a low jumper")

    // Fairness: the autopilot should survive long stretches at every speed.
    var deaths = 0, bestScore = 0, bumps = 0
    for seed in 1...6 {
        let a = Game(art: art, seed: UInt64(seed))
        a.autopilot = true
        a.onDeath = { deaths += 1; bestScore = max(bestScore, Int(a.score)) }
        for _ in 0..<(300 * 120) { a.step(1.0 / 120) }
        bestScore = max(bestScore, Int(a.score))
        bumps += a.turboBumps
    }
    print("autopilot: \(deaths) deaths in 30 simulated minutes, best run \(bestScore), turbo bumps \(bumps)")
    check(deaths <= 6, "autopilot dies too often (\(deaths)) - gaps may be unfair")
    print(fails == 0 ? "selftest OK" : "selftest: \(fails) failures")
    return fails == 0 ? 0 : 1
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest()) }
if args.contains("--snapshot") { snapshot(args); exit(0) }
if args.contains("--record") { record(args); exit(0) }

let app = NSApplication.shared
controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
