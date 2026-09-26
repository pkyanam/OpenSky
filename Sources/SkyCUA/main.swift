import SkyCUALib

@main
struct SkyCUAEntryPoint {
    static func main() async {
        await SkyCUACommandLine.run()
    }
}
