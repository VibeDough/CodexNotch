# Reference boundary

This project uses independently written SwiftUI and AppKit code.

The `boring.notch` project is used only as a behavioral reference for observable interaction ideas such as delayed hover activation, delayed dismissal, top-anchored resizing, gesture discoverability, and temporary status prioritization.

Do not copy its source code, identifiers, constants, view hierarchy, assets, or implementation structure into this project. New behavior must be designed against this project's existing `NotchModel`, `NotchView`, and `NotchPanel` architecture and verified independently.

The reference checkout is kept outside this project at `../boring.notch-reference` and is not a build dependency.
