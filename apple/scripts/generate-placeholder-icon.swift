#!/usr/bin/env swift
//
// Generates a 1024x1024 placeholder app icon PNG.
//
// Usage: swift generate-placeholder-icon.swift <output.png>
//
// Design is deliberately ugly-but-on-brand so "we haven't designed a real
// icon yet" is obvious at a glance. Replace with real artwork before any
// non-internal distribution.

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-placeholder-icon.swift <output.png>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

// Background gradient (indigo → blue).
let bg = NSGradient(starting: NSColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 1),
                    ending: NSColor(red: 0.22, green: 0.44, blue: 0.78, alpha: 1))!
bg.draw(in: NSRect(x: 0, y: 0, width: side, height: side), angle: 90)

// Envelope glyph drawn directly as bezier paths so this script doesn't
// depend on SF Symbols being rasterizable at this size.
NSColor.white.withAlphaComponent(0.95).setFill()
NSColor.white.withAlphaComponent(0.9).setStroke()

let body = NSBezierPath(roundedRect: NSRect(x: 180, y: 320, width: 664, height: 420),
                        xRadius: 36, yRadius: 36)
body.lineWidth = 16
body.fill()
body.stroke()

// Envelope flap: triangle from upper corners down to midpoint.
let flap = NSBezierPath()
flap.move(to: NSPoint(x: 196, y: 720))
flap.line(to: NSPoint(x: 512, y: 470))
flap.line(to: NSPoint(x: 828, y: 720))
flap.lineWidth = 16
NSColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 0.2).setFill()
flap.fill()
NSColor.white.withAlphaComponent(0.9).setStroke()
flap.stroke()

// "cm" wordmark below.
let mark = "cm"
let font = NSFont.systemFont(ofSize: 160, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white.withAlphaComponent(0.85),
]
let textSize = (mark as NSString).size(withAttributes: attrs)
let textOrigin = NSPoint(x: (side - textSize.width) / 2, y: 180)
(mark as NSString).draw(at: textOrigin, withAttributes: attrs)

image.unlockFocus()

guard
    let tiff = image.tiffRepresentation,
    let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Failed to render PNG.\n".utf8))
    exit(1)
}

try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
