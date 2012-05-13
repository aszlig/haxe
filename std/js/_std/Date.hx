/*
 * Copyright (c) 2012, The haXe Project Contributors
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

@:core_api extern class Date
{
	function new(year : Int, month : Int, day : Int, hour : Int, min : Int, sec : Int ) : Void;
	function getTime() : Float;
	function getHours() : Int;
	function getMinutes() : Int;
	function getSeconds() : Int;
	function getFullYear() : Int;
	function getMonth() : Int;
	function getDate() : Int;
	function getDay() : Int;
	function toString():String;
	static function now() : Date;
	static function fromTime( t : Float ) : Date;
	static function fromString( s : String ) : Date;

	private static function __init__() : Void untyped {
		var d = Date;
		d.now = function() {
			return __new__(Date);
		};
		d.fromTime = function(t){
			var d : Date = __new__(Date);
			d["setTime"]( t );
			return d;
		};
		d.fromString = function(s : String) {
			switch( s.length ) {
			case 8: // hh:mm:ss
				var k = s.split(":");
				var d : Date = __new__(Date);
				d["setTime"](0);
				d["setUTCHours"](k[0]);
				d["setUTCMinutes"](k[1]);
				d["setUTCSeconds"](k[2]);
				return d;
			case 10: // YYYY-MM-DD
				var k = s.split("-");
				return new Date(cast k[0],cast k[1] - 1,cast k[2],0,0,0);
			case 19: // YYYY-MM-DD hh:mm:ss
				var k = s.split(" ");
				var y = k[0].split("-");
				var t = k[1].split(":");
				return new Date(cast y[0],cast y[1] - 1,cast y[2],cast t[0],cast t[1],cast t[2]);
			default:
				throw "Invalid date format : " + s;
			}
		};
		d.prototype["toString"] = function() {
			var date : Date = __this__;
			var m = date.getMonth() + 1;
			var d = date.getDate();
			var h = date.getHours();
			var mi = date.getMinutes();
			var s = date.getSeconds();
			return date.getFullYear()
				+"-"+(if( m < 10 ) "0"+m else ""+m)
				+"-"+(if( d < 10 ) "0"+d else ""+d)
				+" "+(if( h < 10 ) "0"+h else ""+h)
				+":"+(if( mi < 10 ) "0"+mi else ""+mi)
				+":"+(if( s < 10 ) "0"+s else ""+s);
		};
		d.prototype.__class__ = __feature__('Type.resolveClass',$hxClasses['Date'] = d,d);
		d.__name__ = ["Date"];
	}
}
