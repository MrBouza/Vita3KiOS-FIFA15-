# Vita3KiOS: creates the iOS app target. Included from vita3k/CMakeLists.txt when IOS is set,
# in place of the desktop executable and the Android shared library.

add_executable(vita3k MACOSX_BUNDLE
	ios/main_ios.cpp
	ios/ios_platform.mm
	ios/ios_session.cpp
	ios/ios_session.h
	interface.cpp
	performance.cpp
)

target_include_directories(vita3k PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})
target_link_libraries(vita3k PRIVATE
	SDL3::SDL3
	pugixml::pugixml
	moltenvk_static
	"-framework Foundation"
	"-framework UIKit"
	"-framework GameController"
	"-framework AVFoundation"
	"-framework CoreMotion"
)

# Objective-C++ sources use ARC
set_source_files_properties(ios/ios_platform.mm PROPERTIES COMPILE_FLAGS "-fobjc-arc")
