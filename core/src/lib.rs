#[cfg(test)]
mod tests {
    #[test]
    fn alacritty_terminal_is_linked() {
        // Will fail to compile until we add the dependency.
        let _ = std::mem::size_of::<alacritty_terminal::term::Config>();
    }
}
