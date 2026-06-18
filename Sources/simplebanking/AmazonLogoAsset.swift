import AppKit

/// Eingebettetes Amazon-Logo (base64) — selbst-enthalten, ohne Resource-Bundle
/// (vermeidet die Bundle.module-Falle). Quelle: amazon.de-Favicon (Smile-Marke).
/// Genutzt für Menüleiste + Flyout des Amazon-eBon-Slots.
enum AmazonLogoAsset {
    static let image: NSImage? = {
        guard let data = Data(base64Encoded: base64.replacingOccurrences(of: "\n", with: "")) else { return nil }
        return NSImage(data: data)
    }()

    private static let base64 = """
iVBORw0KGgoAAAANSUhEUgAAADAAAAAwCAYAAABXAvmHAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAAB
AAEAAKACAAQAAAABAAAAMKADAAQAAAABAAAAMAAAAADbN2wMAAACsUlEQVRoBe1avU4jMRD+HB0SXd6AK4Nowhvw0wMVFdDAO9CAdFBAwTtwdxIKDRUcNT9v
ABQIOniE7ahumW+9E5ysN8rdbsga7Uhre+3x+Ptmxk4kr0GOxJtow2AVMRZFZUaeZo7qqLojMfwoGK4Ew5n5iXvfQqa/M97Cd5lwIP1r/WNjfu/gDTvmFK8u
jh4CAn5JwJ+Iwmd728U0qB0JvnXzC5eq1CWQgr/QgUrXMZaUREIg3sAUJvAgoKvq+X5/RpJObaZTIxmZwGFA4Am5iclkn8Ikpw1wlxAJr5htJEdleMAtYjnm
G7Krec6HKYKde4A/UqHKDAmEcvL4nNy0p5BvKJC+msC4A1VHoI5AQQ/UKVTQgYWnfytsYVQGWvPAtDytOeD51q5yvmdrp8wSWEmVnm5kojyfLVx/+UfvqiRD
8WDi3+nYjjrlcdp1sQ94WDua5TddB9K6RoEkPHj8m/howQKjJ7avATVqe0db0mHqtOebj3bOqv4IUJmMCV6F7Clq3L6VX3LdFXEcazqSJDQjtkxmveweUBVO
pAEloXnJmmQ8+ahT/7kmWDdVaIBrEINGXx3IMUfyI+AoJUaUgNvPNhfRU2IQKYJUUbB8d/v5TnvnKXi+0/sEnxP54QjQkHoijwh1iko/UJJjOume9NgfnoA7
mWTKIqIRzPGwu6yv/X8E1JJGpTWXTQXV8dUKelDK+eZ5+ooR8Bjs5jTzXIVAVQi+RCmfQInghjHl/yEbZmZFdGoC4w5EHYE6AgU98CVSiLeBoUrECDyGip7Y
ecFxFSwBwc4LjrNgCQj2RnoD3gmQRIfY7SlksCMEQtrMEf5il05PCJhjub432AgmCryt/42XLgE2hMQfIbEszSpHgp8adG/pewg4JNrSruKe4Mcebf3EgHgp
xlbZMpTPbd4BPo/LPiPLrKgAAAAASUVORK5CYII=
"""
}
