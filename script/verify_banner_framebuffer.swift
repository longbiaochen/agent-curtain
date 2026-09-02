import CoreGraphics
import Foundation
import ScreenCaptureKit

private let expected = (red: UInt8(191), green: UInt8(26), blue: UInt8(26))
private let tolerance: Int = 12
private let minimumMatchingPixels = 1_000

func matchingPixels(in image: CGImage) -> Int {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else { return 0 }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var count = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        let red = Int(pixels[offset])
        let green = Int(pixels[offset + 1])
        let blue = Int(pixels[offset + 2])
        if abs(red - Int(expected.red)) <= tolerance,
           abs(green - Int(expected.green)) <= tolerance,
           abs(blue - Int(expected.blue)) <= tolerance {
            count += 1
        }
    }
    return count
}

@main
struct FramebufferVerifier {
    static func main() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard !content.displays.isEmpty else {
                fail("framebuffer verifier: no shareable displays", code: 2)
            }

            var failures = 0
            for display in content.displays {
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let configuration = SCStreamConfiguration()
                configuration.width = display.width
                configuration.height = display.height
                configuration.showsCursor = false
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                let matches = matchingPixels(in: image)
                let passed = matches >= minimumMatchingPixels
                print("displayID=\(display.displayID) featurePixels=\(matches) \(passed ? "PASS" : "FAIL")")
                if !passed { failures += 1 }
            }

            if failures > 0 {
                fail("framebuffer verifier: \(failures) display(s) missing the rendered banner", code: 1)
            }
            print("framebuffer verifier: every active display contains the rendered banner feature color")
        } catch {
            fail("framebuffer verifier: capture failed: \(error.localizedDescription)", code: 2)
        }
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
