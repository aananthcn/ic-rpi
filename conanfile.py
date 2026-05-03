from conan import ConanFile
from conan.tools.cmake import CMakeDeps, CMakeToolchain


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

    name = "ic-rpi"
    version = "1.0"
    settings = "os", "arch", "compiler", "build_type"

    requires = (
        "grpc/1.69.0",
        "jsoncpp/1.9.5",
    )

    def build_requirements(self):
        # When cross-compiling (e.g. pc=armv8, build=x86_64), CMake code-gen
        # tools (protoc, grpc_cpp_plugin) must run on the BUILD machine, not the
        # target.  Declaring them as tool_requires causes Conan to add their
        # x86_64 bin dirs to conanbuild.sh, which build.sh sources before cmake.
        # For native pc builds this is a no-op (same arch, same cached package).
        self.tool_requires("protobuf/5.29.6")
        self.tool_requires("grpc/1.69.0")

    def generate(self):
        tc = CMakeToolchain(self)
        tc.generate()
        CMakeDeps(self).generate()
