import Foundation
import Testing
@testable import PortaPackManager

@Suite("AIS-Steckbrief") @MainActor
struct ShipPhotoTests {
    @Test("Commons-Antwort: erstes JPEG mit Urheber und Lizenz")
    func commons() throws {
        let json = #"""
        {"query":{"pages":{
          "2":{"title":"File:B.png","imageinfo":[{"mime":"image/png","thumburl":"https://x/b.png","descriptionurl":"https://c/File:B.png"}]},
          "1":{"title":"File:A ship.jpg","imageinfo":[{"mime":"image/jpeg","thumburl":"https://thumb.wikimedia.org/a.jpg","descriptionurl":"https://commons.wikimedia.org/wiki/File:A_ship.jpg",
               "extmetadata":{"Artist":{"value":"<a href=\"//x\">SVWerder2010</a>"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]}
        }}}
        """#
        let photo = try #require(ShipPhotoLookup.firstPhoto(Data(json.utf8)))
        #expect(photo.imageURL.absoluteString == "https://thumb.wikimedia.org/a.jpg")
        #expect(photo.credit == "Foto: SVWerder2010, CC BY-SA 4.0 · Wikimedia Commons")
        #expect(ShipPhotoLookup.firstPhoto(Data(#"{"batchcomplete":""}"#.utf8)) == nil)
        let subs = ShipPhotoLookup.subcategories(Data(#"{"query":{"categorymembers":[{"ns":14,"title":"Category:Peter Pan (ship, 2022)"}]}}"#.utf8))
        #expect(subs == ["Category:Peter Pan (ship, 2022)"])
    }

    @Test("Urheber: nur der erste Absatz, ohne ©, nie ein ganzer Lizenztext")
    func shortArtist() {
        let html = "<p>© <a href=\"x\">Ra Boe / Wikipedia</a>  \n</p>\n<div class=\"plainlinks\"><a href=\"y\"><span>Create the proper attribution</span></a></div><div>This file is licensed …</div>"
        #expect(ShipPhotoLookup.shortArtist(html) == "Ra Boe / Wikipedia")
        #expect(ShipPhotoLookup.shortArtist("<a href=\"//x\">SVWerder2010</a>") == "SVWerder2010")
        #expect(ShipPhotoLookup.shortArtist(String(repeating: "Wort ", count: 40)).count == 80)
        #expect(ShipPhotoLookup.shortArtist("") == "")
    }

    @Test("ETA aus Meldung 5")
    func eta() {
        #expect(AISETA(month: 10, day: 24, hour: 14, minute: 30)?.text == "24.10. 14:30 UTC")
        #expect(AISETA(month: 10, day: 24, hour: 24, minute: 60)?.text == "24.10.")
        #expect(AISETA(month: 0, day: 0, hour: 24, minute: 60) == nil)
    }
}
