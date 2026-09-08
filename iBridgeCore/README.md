# iBridgeCore — Swift Package

Design system and shared code for iBridge, the iPhone-as-Mac-peripheral
app. Built around **Apple's Liquid Glass** design language (iOS 26+ /
macOS Tahoe+), with SwiftUI Previews for every component.

## Structure

```
iBridgeCore/
├── Package.swift
└── Sources/iBridgeCore/
    ├── DesignSystem/
    │   ├── IBColors.swift        # Light/dark color tokens
    │   ├── IBTypography.swift    # SF Pro + SF Mono scale
    │   ├── IBSpacing.swift       # 4pt base + radii
    │   ├── IBAnimations.swift    # Spring tokens
    │   └── IBMaterials.swift     # Liquid Glass wrappers
    └── Components/
        ├── IBGlassCard.swift          # Generic glass container
        ├── IBStatusPill.swift         # Connection status indicator
        ├── IBModifierBar.swift        # ⌃ ⌥ ⌘ ⇧ toggle row
        ├── IBKeyboardKey.swift        # QWERTY key w/ press animation
        ├── IBPrimaryButton.swift      # Big STOP/STREAM button
        ├── IBToggleRow.swift          # Settings row w/ glass toggle
        ├── IBMicMeter.swift           # Live audio level meter
        └── IBDesignSystemShowcase.swift # All components in one screen
```

## Deployment target

- **iOS 26.0** (Tahoe) — required for `.glassEffect()` API
- **macOS 26.0** (Tahoe) — same

If you need to support iOS 17–25, the `IBMaterial.glass()` helper
falls back to `.regularMaterial` via the `legacyGlass()` modifier.

## Liquid Glass — what this uses

Liquid Glass is Apple's new design language introduced in iOS 26
(June 2025 WWDC) and refined in iOS 27 / macOS 27 Golden Gate
(June 2026 WWDC). It features translucent surfaces with **real
refraction and reflection** of the background, reacting to device
movement on iPhone / iPad.

What we use:
- `glassEffect(.regular.interactive(...))` — translucent panels
- `.glassEffect(.regular, in: shape)` — bars / chips
- `RoundedRectangle(.continuous)` — squircle corners
- Spring animations matching Liquid Glass physics
- Apple's own opacity tier (Primary 100% / Secondary 60% / Tertiary 30%)

Reference: https://developer.apple.com/documentation/technologyoverviews/liquid-glass

## Visualizing the design system in Xcode

Every component has a `#Preview` block. The most useful entry point:

```swift
#Preview {
    IBDesignSystemShowcase()
}
```

This renders every component together on a vivid background so you can
verify Liquid Glass refraction effects are correct after any token change.

## Usage in apps

```swift
import iBridgeCore

struct ContentView: View {
    var body: some View {
        IBGlassCard {
            VStack {
                IBStatusPill(state: .connected(latencyMs: 24))
                IBPrimaryButton(style: .stream)
            }
        }
    }
}
```

## Implementation notes

### Color tokens
Use `IBColor.*` for everything. The `.dynamic(light:dark:)` helper
constructs light/dark-aware colors that automatically follow the
system appearance, including the user's Liquid Glass transparency
preference added in iOS 26.1.

### Typography
Two font families only: **SF Pro** (UI text, titles) and **SF Mono**
(all technical readouts — latency, FPS, bitrate, ISO). This single
discipline is what makes the app feel "professional broadcast gear"
rather than "generic Apple fan app."

### Materials
Never use raw `Color` or `Material` in views. Always go through
`IBMaterial.glass(in:tint:interactive:)`. This guarantees the Liquid
Glass effect is applied consistently and respects the user's
transparency setting.

### Animations
All Use `IBAnimation.*` spring constants. Avoid `linear` and
`easeInOut` — they feel web-y, not Apple-native.