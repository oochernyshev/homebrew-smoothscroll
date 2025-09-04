class Smoothscrolld < Formula
  desc "Background daemon for smooth mouse scrolling on macOS"
  homepage "https://github.com/oochernyshev/homebrew-smoothscroll"
  url "https://github.com/oochernyshev/homebrew-smoothscroll/archive/refs/tags/v0.2.18.tar.gz"
  sha256 "c524b43d781b395e8ab3cb04bed1842512378fab409670292db6b9959f6fc8ca"
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
