class Smoothscrolld < Formula
  desc "Background daemon for smooth mouse scrolling on macOS"
  homepage "https://github.com/oochernyshev/homebrew-smoothscroll"
  url "https://github.com/oochernyshev/homebrew-smoothscroll/archive/refs/tags/v0.2.25.tar.gz"
  sha256 "9330addc9e4076318a0dc6b19aef36644ae96069f4db16e7098bfb4576d81f52"
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
