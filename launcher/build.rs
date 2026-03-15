/// Build script: embeds the application icon on Windows.
fn main() {
    #[cfg(target_os = "windows")]
    {
        // winresource embeds the .ico into the Windows executable so it
        // shows the custom icon in Explorer and on the taskbar.
        let mut res = winresource::WindowsResource::new();
        res.set_icon("../assets/icon.ico");
        if let Err(e) = res.compile() {
            println!("cargo::warning=failed to embed icon: {e}");
        }
    }
}
