# smoothscrolld 🍎

A lightweight macOS background daemon that adds **smooth scrolling** to any mouse.  
This repository contains:

- The **source code** for `smoothscrolld`
- The **Homebrew formula** for easy installation

✨ Features:
- **Smooth**, velocity-based scrolling
- **Inertial natural scrolling** (like a trackpad)
- **Bounce effect at edges** for a native macOS feel


---

## 🔧 Installation (via Homebrew)

Tap and install:

```bash
brew tap oochernyshev/smoothscroll
brew install smoothscrolld
````

Run it as a background service:

```bash
brew services start smoothscrolld
```

Stop the service:

```bash
brew services stop smoothscrolld
```

Check status:

```bash
brew services list
```

---

⚠️ Don’t forget to grant **Accessibility permissions** in
`System Settings → Privacy & Security → Accessibility`.

---

## 📜 License

MIT License © 2025 [Oleg Chernyshev](https://github.com/oochernyshev)
See [LICENSE](LICENSE) for details.
