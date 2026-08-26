# Xanh iOS design system

**Direction:** Calm forest instrument
**Dials:** variance 5/10 · motion 3/10 · density 5/10

This system adapts UI/UX Pro Max guidance to a privacy browser while keeping
SwiftUI and Apple platform conventions ahead of brand decoration.

## Brand

- `Brand/XanhBrowserLogo.png` is the canonical Xanh arrow-mark master.
- `XanhMark` in the asset catalog is the in-app mark. It is decorative when
  placed beside visible `Xanh` text and meaningful only when it has its own
  accessibility label.
- The iOS app icon uses an opaque deep-green field because App Store icons must
  not depend on alpha.

## Semantic colors

| Role | Dark | Light-ready counterpart |
| --- | --- | --- |
| Background | `#050E09` | `#F2F8F3` |
| Panel | `#091B11` | `#FFFFFF` |
| Raised | `#0F2819` | `#E3EFE6` |
| Primary text | `#E8F7EB` | `#102417` |
| Secondary text | `#9BBDA3` | `#405E47` |
| Leaf highlight | `#ABF294` | `#397B32` |
| Xanh green | `#4DD46B` | `#176C31` |
| Destructive | semantic system red | semantic system red |

- Use semantic SwiftUI type styles and Dynamic Type; no fixed body sizes.
- Spacing follows 4/8pt increments. Primary touch targets are at least 44×44pt.
- Prefer SF Symbols for controls and the brand mark only for identity.

## Platform behavior

- Respect safe areas, system gestures, VoiceOver order, keyboard commands,
  reduced motion and accessibility text sizes.
- Use native sheets, menus, confirmation dialogs and materials. Blur indicates
  hierarchy/dismissal, not decoration.
- The bottom chrome is a dock: navigation/address first, then no more than five
  labeled top-level actions. Labels remain available to accessibility even when
  visually compact.
- Profiles own persistent WebKit data stores. Spaces own tab collections.
  Private tabs, history and snapshots never become decorative sync claims.
- Leaf green identifies private context; Xanh green indicates active protection
  or the primary Go action. Always include a text/icon cue besides color.

## Visual language

- Use a calm dark field, a subtle signal path and one centered hero mark. Avoid
  terminal cosplay, purple AI gradients, fake telemetry and excessive cards.
- Cards use 14–22pt continuous radii, one-pixel boundaries and gentle material
  separation. Press feedback changes opacity/surface, never layout bounds.
- Home hierarchy: brand/engine status → one useful search action → concise
  privacy state → shortcuts. Browsing content remains the focus.
