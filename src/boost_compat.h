// Copyright (c) 2009-2012 The Bitcoin developers
// Distributed under the MIT/X11 software license, see the accompanying
// file COPYING or http://www.opensource.org/licenses/mit-license.php.
//
// Compatibility helpers for Boost 1.55 through 1.83+ (Ubuntu 22.04/24.04/26.04).

#ifndef BITCOIN_BOOST_COMPAT_H
#define BITCOIN_BOOST_COMPAT_H

#include <boost/version.hpp>
#include <boost/filesystem.hpp>
#include <boost/bind.hpp>

#if BOOST_VERSION >= 106100
# include <boost/bind/placeholders.hpp>
using boost::placeholders::_1;
using boost::placeholders::_2;
using boost::placeholders::_3;
using boost::placeholders::_4;
using boost::placeholders::_5;
#endif

/* Boost.Filesystem: is_complete() was renamed to is_absolute(). */
#if BOOST_VERSION >= 104600
# define BOOST_FS_IS_COMPLETE(p) ((p).is_absolute())
#else
# define BOOST_FS_IS_COMPLETE(p) ((p).is_complete())
#endif

#endif // BITCOIN_BOOST_COMPAT_H
