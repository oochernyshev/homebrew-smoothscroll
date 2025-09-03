class Smoothscrolld < Formula
  desc "Background daemon for smooth mouse scrolling on macOS"
  homepage "https://github.com/oochernyshev/homebrew-smoothscroll"
  url "https://github.com/oochernyshev/homebrew-smoothscroll/archive/refs/tags/v0.2.2.tar.gz"
  sha256 "<sha256sum>"
  license "MIT"

  depends_on xcode: :build

  def install
    system "swift", "build", "-c", "release"
    bin.install ".build/release/smoothscrolld"
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
