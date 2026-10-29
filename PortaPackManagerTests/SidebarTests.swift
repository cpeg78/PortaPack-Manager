import Testing
@testable import PortaPackManager

@Suite("Seitenleiste")
struct SidebarTests {
    @Test("Jede Seite steht genau einmal in einer Gruppe")
    func everyItemGrouped() {
        let grouped = SidebarItem.groups.flatMap(\.items)
        #expect(Set(grouped) == Set(SidebarItem.allCases))
        #expect(grouped.count == SidebarItem.allCases.count)
    }
}
