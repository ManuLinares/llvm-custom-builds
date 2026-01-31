#!/bin/bash

# Display all commands before executing them.
set -o errexit
set -o errtrace

LLVM_VERSION=$1
LLVM_REPO_URL=${2:-https://github.com/llvm/llvm-project.git}
LLVM_CROSS="$3"

if [[ -z "$LLVM_REPO_URL" || -z "$LLVM_VERSION" ]]
then
  echo "Usage: $0 <llvm-version> <llvm-repository-url> [aarch64/riscv64]"
  echo
  echo "# Arguments"
  echo "  llvm-version         The name of a LLVM release branch without the 'release/' prefix"
  echo "  llvm-repository-url  The URL used to clone LLVM sources (default: https://github.com/llvm/llvm-project.git)"
  echo "  aarch64 / riscv64    To cross-compile an aarch64/riscv64 version of LLVM"

  exit 1
fi

# Clone the LLVM project.
if [ ! -d llvm-project ]
then
	if git clone -b "release/$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="release/$LLVM_VERSION"
	elif git clone -b "llvmorg-$LLVM_VERSION" --single-branch --depth=1 "$LLVM_REPO_URL" llvm-project; then
		LLVM_REF="llvmorg-$LLVM_VERSION"
	else
		echo "Error: Could not find branch 'release/$LLVM_VERSION' or tag 'llvmorg-$LLVM_VERSION'"
		exit 1
	fi
fi

cd llvm-project
git fetch origin
git checkout "$LLVM_REF"
git reset --hard "$LLVM_REF"

# Create directories
mkdir -p build
mkdir -p build_rt

# Adjust compilation based on build type
BUILD_TYPE=$4
if [[ -z "$BUILD_TYPE" ]]; then
  BUILD_TYPE="Release"
fi

# Adjust cross-compilation (Only RISC-V requires cross-compiling on current CI runners)
CROSS_COMPILE=""
TARGET_TRIPLE=""
if [[ "$3" == *riscv64* ]]; then
    TARGET_TRIPLE="riscv64-linux-gnu"
    CROSS_COMPILE="-DLLVM_HOST_TRIPLE=$TARGET_TRIPLE -DCMAKE_C_COMPILER=riscv64-linux-gnu-gcc-13 -DCMAKE_CXX_COMPILER=riscv64-linux-gnu-g++-13 -DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=riscv64"
fi

# Set defaults
ENABLE_ASSERTIONS="OFF"
OPTIMIZED_TABLEGEN="ON"
PARALLEL_LINK_FLAGS=""
BUILD_PARALLEL_FLAGS=""
CMAKE_ARGUMENTS=""

if [[ "$BUILD_TYPE" == "Debug" ]]; then
  BUILD_TYPE="RelWithDebInfo"
  ENABLE_ASSERTIONS="ON"

  if [[ "${OSTYPE}" == linux* ]]; then
    # Grouped Linux-specific Debug optimizations to save memory on CI
    CMAKE_ARGUMENTS="-DLLVM_USE_SPLIT_DWARF=ON"
    #OPTIMIZED_TABLEGEN="OFF"
    PARALLEL_LINK_FLAGS="-DLLVM_PARALLEL_LINK_JOBS=2"
    BUILD_PARALLEL_FLAGS="--parallel 2"
  fi
fi

df -h

# -- PHASE 1: Build LLVM + LLD --
cd build
cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_DISABLE_FIND_PACKAGE_LibXml2=TRUE \
  -DCMAKE_INSTALL_PREFIX="/" \
  -DLLVM_ENABLE_PROJECTS="lld" \
  -DLLVM_ENABLE_RUNTIMES="" \
  -DLLVM_ENABLE_ZLIB=OFF \
  -DLLVM_ENABLE_ZSTD=OFF \
  -DLLVM_TARGETS_TO_BUILD="X86;AArch64;RISCV;WebAssembly;LoongArch;ARM" \
  -DLLVM_INCLUDE_DOCS=OFF \
  -DLLVM_BUILD_TESTS=OFF \
  -DLLVM_BUILD_LLVM_DYLIB=OFF \
  -DLLVM_ENABLE_ASSERTIONS="${ENABLE_ASSERTIONS}" \
  -DLLVM_INCLUDE_EXAMPLES=OFF \
  -DLLVM_INCLUDE_TESTS=OFF \
  -DLLVM_ENABLE_LIBXML2=0 \
  -DLLVM_ENABLE_DOXYGEN=OFF \
  -DLLVM_INCLUDE_BENCHMARKS=OFF \
  -DLLVM_INCLUDE_TOOLS=ON \
  -DLLVM_INCLUDE_RUNTIMES=OFF \
  -DLLVM_INCLUDE_UTILS=OFF \
  -DLLVM_ENABLE_CURL=OFF \
  -DLLVM_ENABLE_BINDINGS=OFF \
  -DLLVM_OPTIMIZED_TABLEGEN="${OPTIMIZED_TABLEGEN}" \
  ${CROSS_COMPILE} \
  ${PARALLEL_LINK_FLAGS} \
  ${CMAKE_ARGUMENTS} \
  ../llvm

cmake --build . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}
DESTDIR=destdir cmake --install . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

# Save some disk space
echo "Initial disk usage:"
df -h
find lib -name "*.o" -type f -delete || true
find lib -name "*.a" -type f -delete || true # I maybe should remove this for the next test
find . -name "*.dwo" -type f -delete || true
echo "Final disk usage:"
df -h

# -- PHASE 2: Build compiler-rt (Builtins & Sanitizers) --
# We need the host triple for standalone compiler-rt build. 
# Skip running llvm-config if cross-compiling to avoid Exec format errors.
HOST_TRIPLE=${TARGET_TRIPLE:-$(./bin/llvm-config --host-target)}

cd ../build_rt
cmake \
  -G Ninja \
  -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
  -DCMAKE_INSTALL_PREFIX="/" \
  -DLLVM_CMAKE_DIR="$(pwd)/../build/lib/cmake/llvm" \
  -DCMAKE_C_COMPILER_TARGET="${HOST_TRIPLE}" \
  -DCOMPILER_RT_BUILD_BUILTINS=ON \
  -DCOMPILER_RT_BUILD_SANITIZERS=ON \
  -DCOMPILER_RT_BUILD_XRAY=OFF \
  -DCOMPILER_RT_BUILD_LIBFUZZER=OFF \
  -DCOMPILER_RT_BUILD_PROFILE=OFF \
  -DCOMPILER_RT_BUILD_MEMPROF=OFF \
  -DCOMPILER_RT_BUILD_ORC=OFF \
  -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON \
  ${CROSS_COMPILE} \
  ${CMAKE_ARGUMENTS} \
  ../compiler-rt

df -h

cmake --build . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

df -h

# Install to the same destdir as LLVM
DESTDIR=../build/destdir cmake --install . --config "${BUILD_TYPE}" ${BUILD_PARALLEL_FLAGS}

df -h
