#!/usr/bin/env swift
/// Generates AppIcon PNG files for DiskMapper.
///
/// Run from the repo root:
///   swift Scripts/generate_icon.swift
///
/// The icon is a dark-grey rounded square with a coloured squarified-treemap
/// pattern of rectangles — visually representing what the app does.

import AppKit
import CoreGraphics

let sizes: [(name: String, px: Int)] = [
    ("AppIcon-16",   16),
    ("AppIcon-32",   32),
    ("AppIcon-64",   64),
    ("AppIcon-128",  128),
    ("AppIcon-256",  256),
    ("AppIcon-512",  512),
    ("AppIcon-1024", 1024),
]

let outputDir = "Sources/DiskMapperApp/Assets.xcassets/AppIcon.appiconset"

// ── Icon design ──────────────────────────────────────────────────────────────
//
// A rounded-rect background filled dark grey, with a simplified treemap mosaic:
//
//  ┌──────────────────────┐
//  │  [  blue  ] [  teal ]│
//  │  [       ]  [──────]│
//  │  [ green  ] [amber ]│
//  │  [        ] [purple]│
//  └──────────────────────┘
//
// Cells proportional to real squarified layout (hard-coded, scale-independent).

struct Cell {
    var rect: CGRect   // in 0…1 unit space
    var r, g, b: CGFloat
}

// Approximate squarified layout for 6 cells — works at any size.
let cells: [Cell] = [
    // Left column: ~55% wide
    Cell(rect: CGRect(x: 0.04, y: 0.04, width: 0.51, height: 0.55),
         r: 0.25, g: 0.50, b: 0.90),   // blue — video
    Cell(rect: CGRect(x: 0.04, y: 0.61, width: 0.51, height: 0.35),
         r: 0.30, g: 0.75, b: 0.55),   // green — images

    // Right column: ~41% wide
    Cell(rect: CGRect(x: 0.59, y: 0.04, width: 0.37, height: 0.30),
         r: 0.25, g: 0.72, b: 0.72),   // teal — audio
    Cell(rect: CGRect(x: 0.59, y: 0.37, width: 0.37, height: 0.25),
         r: 0.90, g: 0.65, b: 0.20),   // amber — documents
    Cell(rect: CGRect(x: 0.59, y: 0.65, width: 0.37, height: 0.19),
         r: 0.65, g: 0.35, b: 0.80),   // purple — archives
    Cell(rect: CGRect(x: 0.59, y: 0.86, width: 0.37, height: 0.10),
         r: 0.85, g: 0.30, b: 0.25),   // red — code
]

func renderIcon(size px: Int) -> NSImage {
    let s = CGFloat(px)
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    guard let ctx = NSGraphicsContext.current?.cgContext else {
        img.unlockFocus(); return img
    }

    // Background: dark grey rounded rect
    let cornerRadius = s * 0.18
    let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    ctx.setFillColor(CGColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1))
    ctx.addPath(bgPath)
    ctx.fillPath()

    // Clip to rounded rect so cells don't spill outside
    ctx.addPath(bgPath)
    ctx.clip()

    // Draw treemap cells
    let padding = s * 0.03
    for cell in cells {
        let r = CGRect(
            x: cell.rect.minX * s + padding,
            y: cell.rect.minY * s + padding,
            width:  cell.rect.width  * s - padding * 2,
            height: cell.rect.height * s - padding * 2
        )
        let cr = max(1.0, s * 0.015)
        let cellPath = CGPath(roundedRect: r, cornerWidth: cr, cornerHeight: cr, transform: nil)
        ctx.setFillColor(CGColor(red: cell.r, green: cell.g, blue: cell.b, alpha: 0.88))
        ctx.addPath(cellPath)
        ctx.fillPath()

        // Subtle inner border
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
        ctx.setLineWidth(max(0.5, s * 0.006))
        ctx.addPath(cellPath)
        ctx.strokePath()
    }

    img.unlockFocus()
    return img
}

// ── Write PNGs ───────────────────────────────────────────────────────────────

let fm = FileManager.default
for spec in sizes {
    let img = renderIcon(size: spec.px)
    guard let tiff = img.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        print("⚠️  Failed to render \(spec.name)")
        continue
    }
    let path = "\(outputDir)/\(spec.name).png"
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✓  \(path)  (\(spec.px)×\(spec.px))")
    } catch {
        print("⚠️  \(path): \(error)")
    }
}
print("Done.")
