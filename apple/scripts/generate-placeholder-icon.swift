#!/usr/bin/env swift
//
// Generates a 1024x1024 placeholder app icon PNG.
//
// Usage: swift generate-placeholder-icon.swift <output.png>
//
// Design is deliberately ugly-but-on-brand so "we haven't designed a real
// icon yet" is obvious at a glance. Replace with real artwork before any
// non-internal distribution.
//
// Implementation note: we draw into a CGContext with explicit pixel
// dimensions rather than NSImage + lockFocus, because lockFocus honors
// the current display's backing scale and would produce a 2048x2048 PNG
// on a retina Mac. App Store validation requires exactly 1024x1024.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-placeholder-icon.swift <output.png>\n".utf8))
    exit(1)
}
let outputPath = CommandLine.arguments[1]

let side = 1024
let bounds = CGRect(x: 0, y: 0, width: side, height: side)

let colorSpace = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: side,
    height: side,
    bitsPerComponent: 8,
    bytesPerRow: side * 4,
    space: colorSpace,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write(Data("Failed to allocate CGContext.\n".utf8))
    exit(1)
}

// Background: vertical gradient indigo -> blue.
let gradColors = [
    CGColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 1),
    CGColor(red: 0.22, green: 0.44, blue: 0.78, alpha: 1),
] as CFArray
guard let gradient = CGGradient(colorsSpace: colorSpace, colors: gradColors, locations: [0, 1]) else {
    exit(1)
}
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: CGFloat(side)),
    options: []
)

// Envelope body — rounded rect, filled and stroked.
ctx.saveGState()
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.95))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.setLineWidth(16)
let bodyRect = CGRect(x: 180, y: 320, width: 664, height: 420)
let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: 36, cornerHeight: 36, transform: nil)
ctx.addPath(bodyPath)
ctx.drawPath(using: .fillStroke)
ctx.restoreGState()

// Envelope flap — triangle.
ctx.saveGState()
ctx.beginPath()
ctx.move(to: CGPoint(x: 196, y: 720))
ctx.addLine(to: CGPoint(x: 512, y: 470))
ctx.addLine(to: CGPoint(x: 828, y: 720))
ctx.closePath()
ctx.setFillColor(CGColor(red: 0.10, green: 0.16, blue: 0.42, alpha: 0.2))
ctx.fillPath()
ctx.beginPath()
ctx.move(to: CGPoint(x: 196, y: 720))
ctx.addLine(to: CGPoint(x: 512, y: 470))
ctx.addLine(to: CGPoint(x: 828, y: 720))
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.setLineWidth(16)
ctx.strokePath()
ctx.restoreGState()

// "cm" wordmark below.
let mark = "cm" as NSString
let font = NSFont.systemFont(ofSize: 160, weight: .bold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white.withAlphaComponent(0.85),
]
let textSize = mark.size(withAttributes: attrs)
let textOrigin = CGPoint(x: (CGFloat(side) - textSize.width) / 2, y: 180)

// Text drawing via Core Text uses the current CGContext. NSGraphicsContext
// bridges AppKit text APIs to our CGContext without involving the display.
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
mark.draw(at: textOrigin, withAttributes: attrs)
NSGraphicsContext.restoreGraphicsState()

// Emit PNG at exactly sideXside pixels.
guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write(Data("Failed to finalize CGImage.\n".utf8))
    exit(1)
}
let outputURL = URL(fileURLWithPath: outputPath)
guard let dest = CGImageDestinationCreateWithURL(
    outputURL as CFURL,
    UTType.png.identifier as CFString,
    1, nil
) else {
    FileHandle.standardError.write(Data("Failed to create image destination.\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else {
    FileHandle.standardError.write(Data("Failed to write PNG.\n".utf8))
    exit(1)
}

print("Wrote \(outputPath) (\(cgImage.width)x\(cgImage.height))")
