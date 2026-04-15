#[cfg(test)]
mod tests {
    #[test]
    fn alacritty_terminal_is_linked() {
        // Proves alacritty_terminal resolves and its core type path is accessible.
        let _ = std::mem::size_of::<alacritty_terminal::term::Config>();
    }
}
