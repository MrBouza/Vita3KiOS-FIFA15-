# Vita3KiOS: app bundle settings and resources. Included from vita3k/CMakeLists.txt when IOS is set.
#
# iOS bundles are flat: the executable, Info.plist and resources all live at the root of Vita3K.app.
# Signing is not done here; CI fake-signs with ldid using ios/Vita3K.entitlements, and the sideloading
# tool (AltStore, SideStore, ...) re-signs with the user's certificate.

set(VITA3K_IOS_BUNDLE_ID "org.vita3k.ios" CACHE STRING "Bundle identifier of the iOS app")
set(VITA3K_IOS_VERSION "1.0.0" CACHE STRING "Marketing version of the iOS app")

set_target_properties(vita3k PROPERTIES
	MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/ios/Info.plist.in"
	MACOSX_BUNDLE_GUI_IDENTIFIER "${VITA3K_IOS_BUNDLE_ID}"
	MACOSX_BUNDLE_BUNDLE_NAME "Vita3K"
	MACOSX_BUNDLE_SHORT_VERSION_STRING "${VITA3K_IOS_VERSION}"
	MACOSX_BUNDLE_BUNDLE_VERSION "${VITA3K_IOS_VERSION}"
	XCODE_ATTRIBUTE_CODE_SIGN_ENTITLEMENTS "${CMAKE_CURRENT_SOURCE_DIR}/ios/Vita3K.entitlements"
	XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
)

add_custom_command(
	TARGET vita3k
	POST_BUILD
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/../data" "$<TARGET_FILE_DIR:vita3k>/data"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/shaders-builtin" "$<TARGET_FILE_DIR:vita3k>/shaders-builtin"
	COMMAND ${CMAKE_COMMAND} -E copy_directory "${CMAKE_CURRENT_SOURCE_DIR}/icons" "$<TARGET_FILE_DIR:vita3k>/icons"
	COMMENT "Copying Vita3K resources into the iOS app bundle")
