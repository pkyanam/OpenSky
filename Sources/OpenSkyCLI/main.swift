import OpenSkyKit

@main
struct OpenSkyEntryPoint {
    static func main() async {
        await OpenSkyCommandLine.run()
    }
}
