/*
 * Copyright (c) 2005, The haXe Project Contributors
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *   - Redistributions of source code must retain the above copyright
 *     notice, this list of conditions and the following disclaimer.
 *   - Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE HAXE PROJECT CONTRIBUTORS "AS IS" AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE HAXE PROJECT CONTRIBUTORS BE LIABLE FOR
 * ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */
package haxe;

typedef TypeResolver = {
	function resolveClass( name : String ) : Class<Dynamic>;
	function resolveEnum( name : String ) : Enum<Dynamic>;
}

class Unserializer {

	public static var DEFAULT_RESOLVER : TypeResolver = Type;

	static var BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789%:";

	#if !neko
	static var CODES = null;

	static function initCodes() {
		var codes =
			#if flash9
				new flash.utils.ByteArray();
			#else
				new Array();
			#end
		for( i in 0...BASE64.length )
			codes[StringTools.fastCodeAt(BASE64,i)] = i;
		return codes;
	}
	#end

 	var buf : String;
 	var pos : Int;
 	var length : Int;
 	var cache : Array<Dynamic>;
 	var scache : Array<String>;
 	var resolver : TypeResolver;
 	#if neko
 	var upos : Int;
 	#end

 	public function new( buf : String ) {
 		this.buf = buf;
 		length = buf.length;
 		pos = 0;
 		#if neko
 		upos = 0;
 		#end
 		scache = new Array();
 		cache = new Array();
		var r = DEFAULT_RESOLVER;
		if( r == null ) {
			r = Type;
			DEFAULT_RESOLVER = r;
		}
 		setResolver(r);
 	}

 	public function setResolver( r ) {
		if( r == null )
			resolver = {
				resolveClass : function(_) { return null; },
				resolveEnum : function(_) { return null; }
			};
		else
			resolver = r;
	}

 	public function getResolver() {
		return resolver;
	}

	inline function get(p) : Int {
		return StringTools.fastCodeAt(buf, p);
	}

 	function readDigits() {
 		var k = 0;
 		var s = false;
 		var fpos = pos;
 		while( true ) {
 			var c = get(pos);
			if( StringTools.isEOF(c) )
				break;
 			if( c == "-".code ) {
 				if( pos != fpos )
 					break;
 				s = true;
 				pos++;
 				continue;
 			}
 			if( c < "0".code || c > "9".code )
 				break;
 			k = k * 10 + (c - "0".code);
 			pos++;
 		}
 		if( s )
 			k *= -1;
 		return k;
 	}

	function unserializeObject(o) {
 		while( true ) {
 			if( pos >= length )
 				throw "Invalid object";
 			if( get(pos) == "g".code )
 				break;
 			var k = unserialize();
 			if( !Std.is(k,String) )
 				throw "Invalid object key";
 			var v = unserialize();
 			Reflect.setField(o,k,v);
 		}
 		pos++;
	}

	function unserializeEnum( edecl, tag ) {
		if( get(pos++) != ":".code )
			throw "Invalid enum format";
		var nargs = readDigits();
		if( nargs == 0 )
			return Type.createEnum(edecl,tag);
		var args = new Array();
		while( nargs-- > 0 )
			args.push(unserialize());
		return Type.createEnum(edecl,tag,args);
	}

 	public function unserialize() : Dynamic {
 		switch( get(pos++) ) {
 		case "n".code:
 			return null;
 		case "t".code:
 			return true;
 		case "f".code:
 			return false;
 		case "z".code:
 			return 0;
 		case "i".code:
 			return readDigits();
 		case "d".code:
 			var p1 = pos;
 			while( true ) {
 				var c = get(pos);
 				// + - . , 0-9
 				if( (c >= 43 && c < 58) || c == "e".code || c == "E".code )
 					pos++;
 				else
 					break;
 			}
 			return Std.parseFloat(buf.substr(p1,pos-p1));
		case "y".code:
 			var len = readDigits();
 			if( get(pos++) != ":".code || length - pos < len )
 				throw "Invalid string length";
			var s = buf.substr(pos,len);
			pos += len;
			s = StringTools.urlDecode(s);
			scache.push(s);
			return s;
 		case "k".code:
 			return Math.NaN;
 		case "m".code:
 			return Math.NEGATIVE_INFINITY;
 		case "p".code:
 			return Math.POSITIVE_INFINITY;
 		case "a".code:
			var buf = buf;
 			var a = new Array<Dynamic>();
 			cache.push(a);
 			while( true ) {
 				var c = get(pos);
 				if( c == "h".code ) {
					pos++;
 					break;
				}
 				if( c == "u".code ) {
					pos++;
 					var n = readDigits();
 					a[a.length+n-1] = null;
 				} else
 					a.push(unserialize());
 			}
 			return a;
 		case "o".code:
	 		var o = {};
	 		cache.push(o);
			unserializeObject(o);
			return o;
 		case "r".code:
 			var n = readDigits();
 			if( n < 0 || n >= cache.length )
 				throw "Invalid reference";
 			return cache[n];
 		case "R".code:
			var n = readDigits();
			if( n < 0 || n >= scache.length )
				throw "Invalid string reference";
			return scache[n];
 		case "x".code:
			throw unserialize();
		case "c".code:
	 		var name = unserialize();
			var cl = resolver.resolveClass(name);
			if( cl == null )
				throw "Class not found " + name;
			var o = Type.createEmptyInstance(cl);
			cache.push(o);
			unserializeObject(o);
			return o;
		case "w".code:
			var name = unserialize();
			var edecl = resolver.resolveEnum(name);
			if( edecl == null )
				throw "Enum not found " + name;
			var e = unserializeEnum(edecl, unserialize());
			cache.push(e);
			return e;
 		case "j".code:
			var name = unserialize();
			var edecl = resolver.resolveEnum(name);
			if( edecl == null )
				throw "Enum not found " + name;
			pos++; /* skip ':' */
			var index = readDigits();
			var tag = Type.getEnumConstructs(edecl)[index];
			if( tag == null )
				throw "Unknown enum index "+name+"@"+index;
			var e = unserializeEnum(edecl, tag);
			cache.push(e);
			return e;
		case "l".code:
			var l = new List();
			cache.push(l);
			var buf = buf;
			while( get(pos) != "h".code )
				l.add(unserialize());
			pos++;
			return l;
		case "b".code:
			var h = new Hash();
			cache.push(h);
			var buf = buf;
			while( get(pos) != "h".code ) {
				var s = unserialize();
				h.set(s,unserialize());
			}
			pos++;
			return h;
		case "q".code:
			var h = new IntHash();
			cache.push(h);
			var buf = buf;
			var c = get(pos++);
			while( c == ":".code ) {
				var i = readDigits();
				h.set(i,unserialize());
				c = get(pos++);
			}
			if( c != "h".code )
				throw "Invalid IntHash format";
			return h;
		case "v".code:
			var d = Date.fromString(buf.substr(pos,19));
			cache.push(d);
			pos += 19;
			return d;
 		case "s".code:
 			var len = readDigits();
			var buf = buf;
 			if( get(pos++) != ":".code || length - pos < len )
				throw "Invalid bytes length";
			#if neko
			var bytes = haxe.io.Bytes.ofData( base_decode(untyped buf.substr(pos,len).__s,untyped BASE64.__s) );
			#else
			var codes = CODES;
			if( codes == null ) {
				codes = initCodes();
				CODES = codes;
			}
			var i = pos;
			var rest = len & 3;
			var size = (len >> 2) * 3 + ((rest >= 2) ? rest - 1 : 0);
			var max = i + (len - rest);
			var bytes = haxe.io.Bytes.alloc(size);
			var bpos = 0;
			while( i < max ) {
				var c1 = codes[StringTools.fastCodeAt(buf,i++)];
				var c2 = codes[StringTools.fastCodeAt(buf,i++)];
				bytes.set(bpos++,(c1 << 2) | (c2 >> 4));
				var c3 = codes[StringTools.fastCodeAt(buf,i++)];
				bytes.set(bpos++,(c2 << 4) | (c3 >> 2));
				var c4 = codes[StringTools.fastCodeAt(buf,i++)];
				bytes.set(bpos++,(c3 << 6) | c4);
			}
			if( rest >= 2 ) {
				var c1 = codes[StringTools.fastCodeAt(buf,i++)];
				var c2 = codes[StringTools.fastCodeAt(buf,i++)];
				bytes.set(bpos++,(c1 << 2) | (c2 >> 4));
				if( rest == 3 ) {
					var c3 = codes[StringTools.fastCodeAt(buf,i++)];
					bytes.set(bpos++,(c2 << 4) | (c3 >> 2));
				}
			}
 			#end
			pos += len;
			cache.push(bytes);
			return bytes;
		case "C".code:
	 		var name = unserialize();
			var cl = resolver.resolveClass(name);
			if( cl == null )
				throw "Class not found " + name;
			var o : Dynamic = Type.createEmptyInstance(cl);
			cache.push(o);
			o.hxUnserialize(this);
			if( get(pos++) != "g".code )
				throw "Invalid custom data";
			return o;
 		default:
 		}
 		pos--;
 		throw ("Invalid char "+buf.charAt(pos)+" at position "+pos);
 	}

	/**
		Unserialize a single value and return it.
	**/
	public static function run( v : String ) : Dynamic {
		return new Unserializer(v).unserialize();
	}

	#if neko
	static var base_decode = neko.Lib.load("std","base_decode",2);
	#end

}
