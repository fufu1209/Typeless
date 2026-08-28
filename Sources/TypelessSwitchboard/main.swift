// SwiftPM 约定：可执行 target 里名为 `main.swift` 的文件可以包含顶层代码。
// 但一旦该 target 有其他源文件，顶层代码就与 `@main` 属性互斥
//（'main' attribute cannot be used in a module that contains top-level code）。
//
// 所以这里把真正实现搬到 `AppMain.swift`（内部用 `@main`），
// `main.swift` 只保留一行调度，让 SwiftUI 的 App 生命周期照常启动。

TypelessSwitchboardMain.main()
