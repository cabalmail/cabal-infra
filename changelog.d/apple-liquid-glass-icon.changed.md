- Apple: **Liquid Glass app icon on iOS 26 and macOS 26.** The iOS/iPadOS and
  macOS square icons moved from flat asset-catalog artwork to an Icon Composer
  `.icon`, so 26+ renders the mark with Liquid Glass material (specular,
  refraction, depth) and the system Default/Dark/Tinted/Clear styles. Older
  OSes (iOS 18–25, macOS 15) keep the flat fallback the compiler emits from the
  same bundle. visionOS keeps its layered parallax icon; watchOS is unchanged.
