class Smoothscrolld < Formula
  desc "Background daemon for smooth mouse scrolling on macOS"
  homepage "https://github.com/oochernyshev/homebrew-smoothscroll"
  url "https://github.com/oochernyshev/homebrew-smoothscroll/archive/refs/tags/v0.2.4.tar.gz"
  sha256 "ebfa665719dde7d43acab7efcef3e17e613fb811e5c7e75231846ffa0c7f941f"
  license "MIT"

  depends_on xcode: :build

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--package-path", "swift"
    bin.install "swift/.build/release/smoothscrolld"
  end

  service do
    run [opt_bin/"smoothscrolld"]
    keep_alive true
    log_path var/"log/smoothscrolld.log"
    error_log_path var/"log/smoothscrolld.log"
  end

  test do
    system "#{bin}/smoothscrolld", "--version"
  end
end
