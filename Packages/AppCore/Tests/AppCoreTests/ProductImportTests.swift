import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AppCore

struct ProductImportTests {
    @Test func listNameAddsBrandAndVariantOnlyWhenMissing() {
        #expect(ExtractedProduct(name: "FINE BUBBLE S", brand: "ReFa").listName == "ReFa FINE BUBBLE S")
        #expect(ExtractedProduct(name: "ReFa FINE BUBBLE S", brand: "ReFa").listName == "ReFa FINE BUBBLE S")
        #expect(ExtractedProduct(name: "Lip Tint", brand: "rom&nd", variant: "#07").listName == "rom&nd Lip Tint #07")
    }

    @Test func decodesExtractedProducts() throws {
        let json = #"{"name":"쿠션","brand":"Clio","variant":null,"search_query":"클리오 쿠션","evidence":"image","confidence":"low"}"#
        let product = try JSONDecoder().decode(ExtractedProduct.self, from: Data(json.utf8))
        #expect(product.searchQuery == "클리오 쿠션" && product.confidence == "low")
    }

    @Test func shoppingItemKeepsImagePath() throws {
        let json = #"{"id":"6f1c3b1e-0000-4000-8000-000000000001","trip_id":"6f1c3b1e-0000-4000-8000-000000000002","name":"ReFa","note":null,"url":null,"added_by":null,"planned_stop_id":null,"image_path":"6f1c3b1e-0000-4000-8000-000000000002/a.jpg"}"#
        let item = try JSONDecoder().decode(ShoppingItem.self, from: Data(json.utf8))
        #expect(item.imagePath == "6f1c3b1e-0000-4000-8000-000000000002/a.jpg")
    }

    @Test func searchLinksEncodeTheQuery() {
        let links = ProductSearchLinks.links(for: "ReFa 蓮蓬頭")
        #expect(links.map(\.title) == ["Instagram", "Threads", "小紅書", "Google"])
        #expect(links[2].url.absoluteString == "https://www.xiaohongshu.com/search_result?keyword=ReFa%20%E8%93%AE%E8%93%AC%E9%A0%AD")
    }

    @Test func downscaleKeepsTheLongSideUnder1024() throws {
        let context = CGContext(data: nil, width: 3000, height: 1500, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0.5, blue: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 3000, height: 1500))
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))

        let jpeg = try #require(ImageDownscale.jpeg(from: png as Data))
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(props[kCGImagePropertyPixelWidth] as? Int == 1024)
        #expect(props[kCGImagePropertyPixelHeight] as? Int == 512)
    }
}
