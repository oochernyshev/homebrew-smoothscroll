# smoothscrolld 🍎

A lightweight macOS background daemon that adds **smooth scrolling** to any mouse.  
This repository contains both:

- The **source code** for `smoothscrolld`
- The **Homebrew formula** for easy installation

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

## ▶️ Manual Build (Swift)

If you prefer to build directly from source:

```bash
git clone https://github.com/oochernyshev/homebrew-smoothscroll.git
cd homebrew-smoothscroll
swift build -c release
```

Binary will be at:

```
.build/release/smoothscrolld
```

Run it:

```bash
./.build/release/smoothscrolld
```

⚠️ Don’t forget to grant **Accessibility permissions** in
`System Settings → Privacy & Security → Accessibility`.

---

## 📂 Repository Layout

```
homebrew-smoothscroll/
 ├─ Formula/               # Homebrew formula(s)
 │   └─ smoothscrolld.rb
 ├─ Sources/               # Swift source code
 │   └─ smoothscrolld/
 │       └─ main.swift
 ├─ Package.swift          # SwiftPM manifest
 ├─ LICENSE
 └─ README.md
```

---

## 🔄 Updating the Formula

When you publish a new release:

1. Update the `url` and `sha256` in [`Formula/smoothscrolld.rb`](Formula/smoothscrolld.rb).
2. Commit and push changes.
3. Users can then update with:

```bash
brew upgrade smoothscrolld
```

---

## 📜 License

MIT License © 2025 [Oleg Chernyshev](https://github.com/oochernyshev)
See [LICENSE](LICENSE) for details.

```
