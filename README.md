Sure thing! Here’s the **`README.md`** content packaged so you can download it directly as a file.
# homebrew-smoothscroll

🍎 A Homebrew tap for installing **smoothscrolld**, a lightweight macOS background daemon that adds smooth scrolling to any mouse.

---

## 🔧 Installation

First, add the tap:

```bash
brew tap oochernyshev/smoothscroll
````

Then install the daemon:

```bash
brew install smoothscrolld
```

---

## ▶️ Usage

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

## 📦 Source Code

The daemon source code lives in a separate repository:

👉 [smoothscrolld on GitHub](https://github.com/oochernyshev/smoothscrolld)

This repository (`homebrew-smoothscroll`) only contains the **Homebrew formula**.

---

## 🔄 Updating the Formula

When a new release is published in the [main repo](https://github.com/oochernyshev/smoothscrolld):

1. Update the `url` and `sha256` in [`Formula/smoothscrolld.rb`](Formula/smoothscrolld.rb).
2. Commit and push the changes here.

---

## 📜 License

MIT License © 2025 [Oleg Chernyshev](https://github.com/oochernyshev)
See [LICENSE](LICENSE) for details.

```