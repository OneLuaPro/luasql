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
project(luasql VERSION 2.7.0 LANGUAGES C)

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
# Specific luasql paths
set(INSTALL_LUASQL_CDIR ${INSTALL_TOP_CDIR}/luasql)

# ------------------------------------------------------------------------------
# Build Options for Drivers (Schalte aus, was du nicht kompilieren kannst)
option(WITH_ODBC       "Build ODBC driver"       ON)
option(WITH_ADO        "Build ADO driver"        ON)
option(WITH_SQLITE     "Build SQLite3 driver"    ON)
option(WITH_MYSQL      "Build MySQL driver"      OFF)
option(WITH_ORACLE     "Build Oracle driver"     OFF)
option(WITH_POSTGRES   "Build PostgreSQL driver" OFF)
option(WITH_FIREBIRD   "Build Firebird driver"   OFF)

# Externe Abhängigkeiten-Pfade (Falls SDKs nicht im Standard-Pfad liegen)
set(SQLITE3_INCLUDE_DIR "${LIBLUA_INCLUDEDIR}" CACHE PATH "Path to sqlite3 header")
set(SQLITE3_LIBRARY     "${LIBLUA_LIBDIR}/sqlean.lib" CACHE FILEPATH "sqlite3 lib")
set(MYSQL_INCLUDE_DIR   "${LIBLUA_INCLUDEDIR}/mariadb" CACHE PATH "Path to mysql.h")
set(MYSQL_LIBRARY       "${LIBLUA_LIBDIR}/mariadb/mariadbclient.lib" CACHE FILEPATH "Path to mysql.lib")
set(ORACLE_INCLUDE_DIR  "" CACHE PATH "Path to Oracle OCI headers")
set(ORACLE_LIBRARY      "" CACHE FILEPATH "Path to oci.lib")
set(POSTGRES_INCLUDE_DIR "" CACHE PATH "Path to pg_config.h / libpq-fe.h")
set(POSTGRES_LIBRARY     "" CACHE FILEPATH "Path to libpq.lib")
set(FIREBIRD_INCLUDE_DIR "" CACHE PATH "Path to ibase.h")
set(FIREBIRD_LIBRARY     "" CACHE FILEPATH "Path to fbclient.lib")

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
    target_compile_definitions(${TARGET_FULL_NAME} PRIVATE
      LUA_BUILD_AS_DLL LUA_LIB _WINDLL _CRT_SECURE_NO_WARNINGS
      LUASQL_VERSION_NUMBER="${PROJECT_VERSION}"
      LUASQL_API=LUALIB_API
    )
    
    target_link_directories(${TARGET_FULL_NAME} PRIVATE ${LIBLUA_LIBDIR})
    target_link_libraries(${TARGET_FULL_NAME} PRIVATE
      ${EXT_LIBS}
      zlibstatic.lib zstd_static.lib libcurl.lib
      brotlicommon.lib brotlidec.lib
      nghttp2.lib nghttp3.lib ngtcp2.lib ngtcp2_crypto_libressl.lib
      ssl.lib crypto.lib
      liblua.lib secur32.lib rpcrt4.lib crypt32.lib
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

#add_luasql_driver(ado "src/ls_ado.c" "" "")


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
