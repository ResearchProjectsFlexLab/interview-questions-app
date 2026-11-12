//
//  SceneFade.swift
//  Interview Questions
//
//  Cross-fades between the moonlit lake (rests) and the interview office.
//

import RealityKit
import Foundation

// MARK: - Cross-fade between the lake and the office

/// Fades an entity's opacity toward `target` over about two-thirds of a second.
struct FadeComponent: Component {
    var target: Float
}

struct FadeSystem: System {
    static let query = EntityQuery(where: .has(FadeComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let step = Float(context.deltaTime) * 1.5
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let fade = entity.components[FadeComponent.self] else { continue }
            let current = entity.components[OpacityComponent.self]?.opacity ?? 1
            guard current != fade.target else { continue }
            let next = current < fade.target ? min(fade.target, current + step) : max(fade.target, current - step)
            entity.components.set(OpacityComponent(opacity: next))
        }
    }
}

/// Deterministic random numbers so the scene looks the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
