# Specification of the minimum cmake version this script expects. If the system
# has an older cmake version installed, the build will fail. This option is
# very important, because many things changed in cmake and the minimum version
# guarantees you that a certain set of function are available and that their
# behaviour as as you would expect. However, normally the precise version does
# not matter too much. If in doubt, just refer to the cmake documentation.
cmake_minimum_required(VERSION 3.5)

# Declare a project. The only required argument is the name, everything else is
# optional metadata. This is similar to the concept of a package in other
# languages.
project(HelloWorld VERSION 1.0.0 LANGUAGES C)

# Find a threads library. Prefer pthreads if multiple libraries are available.
set(CMAKE_THREAD_PREFER_PTHREAD TRUE)
find_package(Threads REQUIRED)

# Normally cmake would build the specified targets in Debug mode. The following
# lines change the default build type to release while still allowing the caller
# of cmake of override this setting (see usage in the last comment of this file)

# set a variable to our preferred build type
set(DEFAULT_BUILD_TYPE "Release")
# `CMAKE_BUILD_TYPE` is a magic variable used by cmake to identify the desired
# build type. If the caller didn't specify it explicitly, this variable is not
# defined. In this case we set it to Release. Otherwise, we just leave it at the
# value the caller specified
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "${DEFAULT_BUILD_TYPE}" CACHE STRING "Choose the type of build." FORCE)
endif()

# Declare an executable. A project can actually comprise multiple executables
# and/or libraries. The first argument is the name of the executable,
# subsequent arguments are source files.  To build from multiple sources,
# additional files can be simply added to the list.
add_executable(HelloWorld HelloWorld.c)

# Link the HelloWorld target to the threads library. The list can be extended
# by arbitrary libraries. Note that the target `Threads::Threads` is provided
# by the call to `find_packahe(Threads)` above. The exact names to specify here
# depend on the concrete package you try to link to.
target_link_libraries(HelloWorld Threads::Threads)

# The following directive is not needed here, but it might be useful for future
# us.  It allows to specify any additional include directories that might be
# required.  Note that the `target_link_libraries` call above already ensures
# that any headers provided by the library are already visible.  This call
# should just add additional paths in our own source tree. `PROJECT_SOURCE_DIR`
# refers to the directory containing the thie CMakeLists.txt.

#target_include_directories(HelloWorld PUBLIC "${PROJECT_SOURCE_DIR}/include")

# An install directive. This simply tells cmake to place the HelloWorld binary
# in the bin directory (At least on Linux, it might choose other directory
# names on other platforms respecting the conventions of that platform).
# Installing is simple for a single binary, but can become more tricky if
# additional libraries are involved (e.g. reactor-cpp for C++ targets).
install(TARGETS HelloWorld RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

# USAGE
#
# - Run lfc to generate the c source code for HelloWorld.lf.
# - Copy this file to the src-gen directory.
# - In src-gen, create a build directory.
# - In the build directory, run `cmake .. -DCMAKE_INSTALL_PREFIX=../..`
# - In the build directory, run `make install`. To see the actual commands
#    invoked, you can run make with `VERBOSE=1`.
#
# Note that the build directory can be located anywhere in the file system, it
# does not need to be a subdirectory of src-gen. (it could even be src-gen
# itself, but building in the source directory is discouraged. Cmake simply
# expects the source directory (the one containing CMakeLists.txt) as its first
# positional argument. Note that you might need to adjust the
# `-DCMAKE_INSTALL_PREFIX` in order to point to the correct install location.
#
# On Linux and Mac, cmake will generate Makefiles and the build can be invoked
# directly by calling make. However, on other platforms cmake will use other
# build mechanisms. Most importantly cmake will create an MSVC project. The
# following command can be used to invoke the build independent of the platform
# (this will then call make or another build tool used):
#
# `cmake --build . --target install --config Realease`
#
# Note that when using this option cmake will still fall back to the Debug
# build type on default and you need to specify `--config Realease` to create a
# release build. (I am not sure why)
#
# In LF "projects" that specify multiple LF programs like it is the case in
# this test directory, compiling multiple programs can become problematic.
# Each invocation of lfc would actually need to override the CMakeLists.txt.
# I (CM) see too options to solve this issue: generate code for the entire LF
# project and create on CMakeLists.txt declaring one executable for each main
# reactor found, or generate code for individual LF programs in subdirectories
# of src-gen. The later option is what C++ currently does.
