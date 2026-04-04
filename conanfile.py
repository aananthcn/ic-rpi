from conan import ConanFile
from conan.tools.cmake import CMakeToolchain, CMakeDeps


class IcRpi5Conan(ConanFile):
    """
    Integration project: Instrument Cluster on Raspberry Pi 5.

    Declares the union of all sub-project dependencies so a single
    'conan install' populates the build folder with every package needed
    by both vhal-core and cluster-ui.

    Sub-projects and their deps:
        vhal-core  : grpc/1.69.0, jsoncpp/1.9.5
        cluster-ui : grpc/1.69.0  (Qt is system-installed, not via Conan)
    """
    name = "ic-rpi5"
    version = "1.0"
    settings = "os", "arch", "compiler", "build_type"

    requires = (
        "grpc/1.69.0",
        "jsoncpp/1.9.5",
    )

    def generate(self):
        tc = CMakeToolchain(self)
        tc.generate()
        CMakeDeps(self).generate()
