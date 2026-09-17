@_exported import PaydayCore

// PaydayCore PR 0 (see docs/CI.md, docs/PRODUCT.md Pillar 8): moving symbols
// like `Money` into the PaydayCore package would otherwise force every call
// site across both processes (the app target and the PaydayWidget
// extension) to add its own `import PaydayCore`. Re-exporting it here once,
// from a file that both the app's implicit source folder and the widget's
// explicit source list compile, lets every existing unqualified `Money`
// call site keep compiling unchanged while the type actually lives in the
// package.
