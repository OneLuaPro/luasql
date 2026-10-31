# ------------------------------------------------------------------------------
# CMake for luasql
# ------------------------------------------------------------------------------
# Setup with Visual Studio 17 2022 generator for x64
# ------------------------------------------------------------------------------
# Visual Studio is a mutlti-configuration generator
# https://stackoverflow.com/questions/24460486/
#
# Basic instructions for out-of-source build
# ------------------------------------------
# mkdir build && cd build
# cmake .. -G "Visual Studio 17 2022" -A x64
# cmake --build . --config Release
# cmake --install . --config Release
# 
# Available architectures (-A ...) are: Win32, x64, ARM, ARM64

# ------------------------------------------------------------------------------
# General definitions
cmake_minimum_required(VERSION 3.23 FATAL_ERROR)

# ------------------------------------------------------------------------------
# find liblua installation and version info
if(NOT LUA_HINTS)
  if(WIN32)
    set(LUA_HINTS "c:/Apps")
  endif()
endif()
find_package(liblua REQUIRED CONFIG HINTS ${LUA_HINTS})
if(liblua_FOUND)
  message(STATUS "liblua version        : ${liblua_VERSION}")
  message(STATUS "liblua install prefix : ${LIBLUA_INSTALLDIR}")
  message(STATUS "liblua include dir    : ${LIBLUA_INCLUDEDIR}")
  message(STATUS "liblua lib dir        : ${LIBLUA_LIBDIR}")
else()
  message(FATAL_ERROR "Unable to find liblua version ${liblua_VERSION}.")
endif()
# Note: liblua_VERSION is set by find_package() directly. LIBLUA_INSTALLDIR,
# LIBLUA_INCLUDEDIR and LIBLUA_LIBDIR are set by libluaConfigVersion.cmake in
# <prefix>/share/cmake/liblua.

# ------------------------------------------------------------------------------
# Installation prefix directory - automatically set from find_package()
# Needs to be defined before project definition statement - for whatever reason
if(NOT CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX ${LIBLUA_INSTALLDIR})
endif()

# ------------------------------------------------------------------------------
# Project definition
project(luasql VERSION 2.8.1 LANGUAGES C)

# ------------------------------------------------------------------------------
# Setup GNU-alike installatin directories
include (GNUInstallDirs)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/${CMAKE_INSTALL_LIBDIR})
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/${CMAKE_INSTALL_LIBDIR})
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${PROJECT_BINARY_DIR}/${CMAKE_INSTALL_BINDIR})
set(INSTALL_LIBDIR
  ${CMAKE_INSTALL_LIBDIR} CACHE PATH "Installation directory for libraries")
set(INSTALL_BINDIR
  ${CMAKE_INSTALL_BINDIR} CACHE PATH "Installation directory for executables")
set(INSTALL_INCLUDEDIR
  ${CMAKE_INSTALL_INCLUDEDIR} CACHE PATH "Installation directory for header files")
set(INSTALL_DOCDIR
  ${CMAKE_INSTALL_DOCDIR} CACHE PATH "Installation directory for documentation")
set(INSTALL_MANDIR
  ${CMAKE_INSTALL_MANDIR} CACHE PATH "Installation directory for manpages")
set(INSTALL_DATAROOTDIR
  ${CMAKE_INSTALL_DATAROOTDIR} CACHE PATH "Installation directory for data")
# Lua-specific installation dirs
set(INSTALL_TOP_CDIR
  ${INSTALL_LIBDIR}/lua/${liblua_VERSION_MAJOR}.${liblua_VERSION_MINOR})
set(INSTALL_TOP_LDIR
  ${INSTALL_DATAROOTDIR}/lua/${liblua_VERSION_MAJOR}.${liblua_VERSION_MINOR})
# Specific luasql paths
set(INSTALL_LUASQL_CDIR ${INSTALL_TOP_CDIR}/luasql)
set(INSTALL_LUASQL_LDIR ${INSTALL_TOP_LDIR}/luasql)

# ------------------------------------------------------------------------------
# Get AWS SDK path and settings
get_filename_component(AWS_PREFIX "${LIBLUA_LIBDIR}/.." ABSOLUTE)
list(APPEND CMAKE_PREFIX_PATH "${AWS_PREFIX}")
find_package(ZLIB REQUIRED)
find_package(AWSSDK REQUIRED COMPONENTS core sso sts identity-management rds)
message(STATUS "AWS SDK link libraries: ${AWSSDK_LINK_LIBRARIES}")
#
find_package(azure-identity-cpp CONFIG REQUIRED)
find_package(azure-storage-blobs-cpp CONFIG REQUIRED)
find_package(azure-storage-files-datalake-cpp CONFIG REQUIRED)

# ------------------------------------------------------------------------------
# spatial: the same find_package calls and the same order as in
# duckdb-spatial's CMakeLists.txt (PROJ before GDAL, see gdal_smoke)
#
# Hints for sqlean.lib in the spelling that CMake's FindSQLite3 reads. The variable
# names are case sensitive, the SQLITE3_* variables below are not seen by it.
set(SQLite3_INCLUDE_DIR "${LIBLUA_INCLUDEDIR}" CACHE PATH "Path to sqlite3 header")
set(SQLite3_LIBRARY     "${LIBLUA_LIBDIR}/sqlean.lib" CACHE FILEPATH "sqlite3 lib (sqlean)")
set(OPENSSL_USE_STATIC_LIBS ON)
find_package(OpenSSL REQUIRED)
find_package(PROJ CONFIG REQUIRED)
find_package(GDAL CONFIG REQUIRED)
find_package(GEOS REQUIRED)
find_package(sqlean CONFIG REQUIRED)
find_package(CURL REQUIRED)

# ------------------------------------------------------------------------------
# Externe Abhaengigkeiten-Pfade (Falls SDKs nicht im Standard-Pfad liegen)
set(SQLITE3_INCLUDE_DIR  "${LIBLUA_INCLUDEDIR}" CACHE PATH "Path to sqlite3 header")
set(SQLITE3_LIBRARY      "${LIBLUA_LIBDIR}/sqlean.lib" CACHE FILEPATH "sqlite3 lib")
set(MYSQL_INCLUDE_DIR    "${LIBLUA_INCLUDEDIR}/mariadb" CACHE PATH "Path to mysql.h")
set(MYSQL_LIBRARY        "${LIBLUA_LIBDIR}/mariadb/mariadbclient.lib" CACHE FILEPATH "Path to mysql.lib")
set(POSTGRES_INCLUDE_DIR "${LIBLUA_INCLUDEDIR}" CACHE PATH "Path to postgres header")
set(POSTGRES_LIBRARY     "${LIBLUA_LIBDIR}/pq.lib" CACHE FILEPATH "Path to pq.lib")
set(DUCKDB_INCLUDE_DIR   "${LIBLUA_INCLUDEDIR}" CACHE PATH "Path to duckdb.h")
set(DUCKDB_LIBRARY       "duckdb_static.lib;core_functions_extension.lib;parquet_extension.lib;json_extension.lib;duckdb_generated_extension_loader.lib;postgres_scanner_extension.lib;pq.lib;mysql_scanner_extension.lib;${LIBLUA_LIBDIR}/mariadb/mariadbclient.lib;sqlite_scanner_extension.lib;sqlean.lib;odbc_scanner_extension.lib;odbc32.lib;httpfs_extension.lib;excel_extension.lib;libexpatMT.lib;minizip-ng.lib;bzip2.lib;lzma.lib;ppmd.lib;fts_extension.lib;aws_extension.lib;${AWSSDK_LINK_LIBRARIES};azure_extension.lib;Azure::azure-identity;Azure::azure-storage-blobs;Azure::azure-storage-files-datalake;flatccrt.lib;vss_extension.lib;spatial_extension.lib;GDAL::GDAL;PROJ::proj;GEOS::geos_c;sqlean::sqlean;ZLIB::ZLIB;CURL::libcurl;OpenSSL::SSL;OpenSSL::Crypto;wbemuuid.lib" CACHE STRING "DuckDB static libraries and their transitive dependencies")

set(ORACLE_INCLUDE_DIR  "" CACHE PATH "Path to Oracle OCI headers")
set(ORACLE_LIBRARY      "" CACHE FILEPATH "Path to oci.lib")
set(FIREBIRD_INCLUDE_DIR "${LIBLUA_INCLUDEDIR}" CACHE PATH "Path to ibase.h")
set(FIREBIRD_LIBRARY     "fbclient_static.lib;tomcrypt.lib;tommath.lib;mpr.lib" CACHE STRING "Firebird static client and its dependencies")

# ------------------------------------------------------------------------------
macro(add_luasql_driver DRIVER_NAME SOURCES_LIST EXT_INCLUDES EXT_LIBS)
  set(TARGET_FULL_NAME "luasql_${DRIVER_NAME}")
  add_library(${TARGET_FULL_NAME} SHARED src/luasql.c ${SOURCES_LIST})

  set_target_properties(${TARGET_FULL_NAME} PROPERTIES 
    PREFIX "" 
    OUTPUT_NAME "${DRIVER_NAME}"
    LIBRARY_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/${CMAKE_INSTALL_LIBDIR}/luasql"
    RUNTIME_OUTPUT_DIRECTORY "${PROJECT_BINARY_DIR}/${CMAKE_INSTALL_BINDIR}/luasql"
  )

  target_include_directories(${TARGET_FULL_NAME} PRIVATE
    ${LIBLUA_INCLUDEDIR} ${EXT_INCLUDES}
  )
  
  if(WIN32 AND NOT MinGW)
    if (${DRIVER_NAME} STREQUAL "oci8")
      target_link_options(${TARGET_FULL_NAME} PRIVATE
	"LINKER:/DELAYLOAD:oci.dll"
	"LINKER:/DEPENDENTLOADFLAG:0x0"
      )
      # delayimp.lib provides the delay-load helper (lazy loading of oci.dll)
      target_link_libraries(${TARGET_FULL_NAME} PRIVATE delayimp.lib)
    endif()

    target_compile_definitions(${TARGET_FULL_NAME} PRIVATE
      LUA_BUILD_AS_DLL LUA_LIB _WINDLL _CRT_SECURE_NO_WARNINGS
      LUASQL_VERSION_NUMBER="${PROJECT_VERSION}"
      LUASQL_API=LUALIB_API
      DUCKDB_STATIC_BUILD
    )
    
    target_link_directories(${TARGET_FULL_NAME} PRIVATE ${LIBLUA_LIBDIR})
    target_link_libraries(${TARGET_FULL_NAME} PRIVATE
      ${EXT_LIBS}
      rstrtmgr.lib
      zlibstatic.lib zstd_static.lib libcurl.lib
      brotlicommon.lib brotlidec.lib
      nghttp2.lib nghttp3.lib ngtcp2.lib ngtcp2_crypto_libressl.lib
      ssl.lib crypto.lib
      liblua.lib ws2_32.lib secur32.lib rpcrt4.lib crypt32.lib
      iphlpapi.lib bcrypt.lib shlwapi.lib wldap32.lib normaliz.lib
    )
  else()
    message(FATAL_ERROR "Not yet fully implemented for this platform.")
  endif()

  install(TARGETS ${TARGET_FULL_NAME} RUNTIME DESTINATION ${INSTALL_LUASQL_CDIR})
endmacro()

# ------------------------------------------------------------------------------
# DB-Drivers

message(STATUS "Configuring LuaSQL-ODBC...")
add_luasql_driver(odbc "src/ls_odbc.c" "" "odbc32.lib")
message(STATUS "Configuring LuaSQL-SQLite3...")
add_luasql_driver(sqlite3 "src/ls_sqlite3.c" "${SQLITE3_INCLUDE_DIR}" "${SQLITE3_LIBRARY}")
message(STATUS "Configuring LuaSQL-MySQL...")
add_luasql_driver(mysql "src/ls_mysql.c" "${MYSQL_INCLUDE_DIR}" "${MYSQL_LIBRARY}")
message(STATUS "Configuring LuaSQL-PostgreSQL...")
add_luasql_driver(postgres "src/ls_postgres.c" "${POSTGRES_INCLUDE_DIR}" "${POSTGRES_LIBRARY}")
message(STATUS "Configuring DuckDB...")
add_luasql_driver(duckdb "src/ls_duckdb.c" "${DUCKDB_INCLUDE_DIR}" "${DUCKDB_LIBRARY}")
message(STATUS "Configuring LuaSQL-Firebird...")
add_luasql_driver(firebird "src/ls_firebird.c" "${FIREBIRD_INCLUDE_DIR}" "${FIREBIRD_LIBRARY}")
message(STATUS "Configuring LuaSQL-ADO (pure Lua, needs luacom at runtime)...")
install(FILES src/ado/ado.lua DESTINATION ${INSTALL_LUASQL_LDIR})
message(STATUS "Configuring LuaSQL-Oracle (OCI8)...")
add_luasql_driver(oci8 "src/ls_oci8.c" "${ORACLE_INCLUDE_DIR}" "${ORACLE_LIBRARY}")

# ------------------------------------------------------------------------------
# Documentation (LDoc)
# Generated from the LDoc comments in src/ and from doc/ldoc (manual, examples,
# style) into <build>/doc, installed to <prefix>/share/doc/luasql. Needs ldoc,
# e.g. the one of the OneLuaPro installation; skipped with a warning without.
option(LUASQL_BUILD_DOC "Generate the LDoc documentation" ON)
if(LUASQL_BUILD_DOC)
  find_program(LDOC_EXECUTABLE NAMES ldoc ldoc.bat
    HINTS "${CMAKE_INSTALL_PREFIX}/bin" "${LIBLUA_INSTALLDIR}/bin")
  if(LDOC_EXECUTABLE)
    message(STATUS "LDoc                  : ${LDOC_EXECUTABLE}")
    set(LUASQL_DOC_DIR "${PROJECT_BINARY_DIR}/doc")
    file(GLOB LUASQL_DOC_SOURCES CONFIGURE_DEPENDS
      "${CMAKE_CURRENT_SOURCE_DIR}/doc/ldoc/*.*"
      "${CMAKE_CURRENT_SOURCE_DIR}/doc/ldoc/manual/*.md"
      "${CMAKE_CURRENT_SOURCE_DIR}/doc/ldoc/examples/*.lua"
    )
    # ldoc reads the configuration, changes to its directory and resolves
    # the paths in it from there; the output directory is absolute
    add_custom_command(
      OUTPUT "${LUASQL_DOC_DIR}/index.html"
      COMMAND "${LDOC_EXECUTABLE}" -c doc/ldoc/config.ld -d "${LUASQL_DOC_DIR}" .
      WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
      DEPENDS ${LUASQL_DOC_SOURCES} "${CMAKE_CURRENT_SOURCE_DIR}/src/ls_oci8.c"
      COMMENT "Generating the LuaSQL documentation with LDoc..."
      VERBATIM
    )
    add_custom_target(luasql_doc ALL DEPENDS "${LUASQL_DOC_DIR}/index.html")
    install(DIRECTORY "${LUASQL_DOC_DIR}/"
      DESTINATION "${CMAKE_INSTALL_DATAROOTDIR}/doc/luasql")
  else()
    message(WARNING "ldoc not found: the LuaSQL documentation is not generated")
  endif()
endif()

# # 1. ODBC (Nutzt Windows native odbc32.lib)
# if(WITH_ODBC)
#     message(STATUS "Configuring LuaSQL-ODBC...")
#     add_luasql_driver(odbc "src/ls_odbc.c" "" "odbc32.lib")
# endif()

# # 2. ADO (Nutzt Windows native COM / Setzt voraus, dass LuaCOM geladen ist)
# if(WITH_ADO)
#     message(STATUS "Configuring LuaSQL-ADO...")
#     # Hinweis: Falls spezielle LuaCOM-C-Header gebraucht werden, hier im 3. Parameter den Pfad übergeben
#     add_luasql_driver(ado "src/ls_ado.c" "" "")
# endif()

# # 3. SQLite3
# if(WITH_SQLITE)
#     message(STATUS "Configuring LuaSQL-SQLite3...")
#     if(NOT SQLITE3_LIBRARY)
#         find_package(SQLite3 REQUIRED)
#         set(SQLITE3_INCLUDE_DIR ${SQLite3_INCLUDE_DIRS})
#         set(SQLITE3_LIBRARY ${SQLite3_LIBRARIES})
#     endif()
#     add_luasql_driver(sqlite3 "src/ls_sqlite3.c" "${SQLITE3_INCLUDE_DIR}" "${SQLITE3_LIBRARY}")
# endif()

# # 4. MySQL
# if(WITH_MYSQL)
#     message(STATUS "Configuring LuaSQL-MySQL...")
#     if(NOT MYSQL_LIBRARY)
#         message(FATAL_ERROR "Please specify MYSQL_INCLUDE_DIR and MYSQL_LIBRARY")
#     endif()
#     add_luasql_driver(mysql "src/ls_mysql.c" "${MYSQL_INCLUDE_DIR}" "${MYSQL_LIBRARY}")
# endif()

# # 5. Oracle
# if(WITH_ORACLE)
#     message(STATUS "Configuring LuaSQL-Oracle (OCI8)...")
#     if(NOT ORACLE_LIBRARY)
#         message(FATAL_ERROR "Please specify ORACLE_INCLUDE_DIR and ORACLE_LIBRARY")
#     endif()
#     add_luasql_driver(oci8 "src/ls_oci8.c" "${ORACLE_INCLUDE_DIR}" "${ORACLE_LIBRARY}")
# endif()

# # 6. PostgreSQL
# if(WITH_POSTGRES)
#     message(STATUS "Configuring LuaSQL-PostgreSQL...")
#     if(NOT POSTGRES_LIBRARY)
#         message(FATAL_ERROR "Please specify POSTGRES_INCLUDE_DIR and POSTGRES_LIBRARY")
#     endif()
#     add_luasql_driver(postgres "src/ls_postgres.c" "${POSTGRES_INCLUDE_DIR}" "${POSTGRES_LIBRARY}")
# endif()

# # 7. Firebird
# if(WITH_FIREBIRD)
#     message(STATUS "Configuring LuaSQL-Firebird...")
#     if(NOT FIREBIRD_LIBRARY)
#         message(FATAL_ERROR "Please specify FIREBIRD_INCLUDE_DIR and FIREBIRD_LIBRARY")
#     endif()
#     add_luasql_driver(firebird "src/ls_firebird.c" "${FIREBIRD_INCLUDE_DIR}" "${FIREBIRD_LIBRARY}")
# endif()

# # ------------------------------------------------------------------------------
# # Install docs (optional)
# if(IS_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/doc")
#     install(DIRECTORY doc/ DESTINATION ${INSTALL_DOCDIR})
# endif()
