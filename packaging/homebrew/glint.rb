# Homebrew formula for the macOS host.
#
# It builds from source rather than shipping a bottle because the host links
# libusb from Homebrew's own prefix; a prebuilt binary would hard-code a path
# that differs on Intel and Apple Silicon.
#
# This installs the host CLI only. Flashing a panel needs ESP-IDF and a source
# checkout, or a firmware zip from a release.
#
# To publish: create a repository named `homebrew-glint`, put this file in it as
# Formula/glint.rb, then
#   brew tap shubham030/glint
#   brew install glint
class Glint < Formula
  desc "Drive an ESP32 LCD panel as a second display"
  homepage "https://github.com/shubham030/glint"
  url "https://github.com/shubham030/glint/archive/refs/tags/v0.1.0.tar.gz"
  # sha256 is printed by: brew fetch --build-from-source glint
  sha256 ""
  license "MIT"
  head "https://github.com/shubham030/glint.git", branch: "main"

  depends_on "libusb"
  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox",
           "--package-path", "host"
    bin.install "host/.build/release/glint"
  end

  test do
    # doctor runs without a panel and reports what it found; it exits non-zero
    # when something is missing, which is expected in a sandbox.
    assert_match "glint doctor", shell_output("#{bin}/glint doctor", 1)
  end
end
