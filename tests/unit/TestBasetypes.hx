package unit;

class TestBasetypes extends Test {

	function testArray() {
		var a : Array<Null<Int>> = [1,2,3];
		eq( a.length, 3 );
		eq( a[0], 1 );
		eq( a[2], 3 );

		eq( a[3], null );
		eq( a[1000], null );
		eq( a[-1], null );

		a.remove(2);
		eq( a.length, 2);
		eq( a[0], 1 );
		eq( a[1], 3 );
		eq( a[2], null );

		var a : Array<Null<Int>> = [1,2,3];
		a.splice(1,1);
		eq( a.length, 2 );
		eq( a[0], 1 );
		eq( a[1], 3 );
		eq( a[2], null );
	}

	function testString() {
		eq( String.fromCharCode(77), "M" );
		unspec(function() String.fromCharCode(0));
		unspec(function() String.fromCharCode(-1));
		unspec(function() String.fromCharCode(256));
#if php
		eq( Std.string(null) + "x", "nullx" );
		eq( "x" + Std.string(null), "xnull" );
#else
		eq( null + "x", "nullx" );
		eq( "x" + null, "xnull" );
#end

		var abc = "abc".split("");
		eq( abc.length, 3 );
		eq( abc[0], "a" );
		eq( abc[1], "b" );
		eq( abc[2], "c" );
		
		var str = "abc";
		eq( str.charCodeAt(0), "a".code );
		eq( str.charCodeAt(1), "b".code );
		eq( str.charCodeAt(2), "c".code );
		eq( str.charCodeAt(-1), null );
		eq( str.charCodeAt(3), null );
		
		// substr tests
		var sentence:String = "Pack my box with five dozen liquor jugs.";
		eq(sentence.substr(0, 4), "Pack");
		eq(sentence.substr(5, 2), "my");
		eq(sentence.substr(0), sentence);
		eq(sentence.substr(35), "jugs.");
		eq(sentence.substr(40), "");
		eq(sentence.substr(42), "");
		eq(sentence.substr(-5, 4), "jugs");
		eq(sentence.substr(-5), "jugs.");
		eq(sentence.substr(-42), sentence);
		eq(sentence.substr(4, 0), "");
		eq(sentence.substr(0, -36), "Pack");
		
		// null should not be swallowed
		eq("hello" +null, "hellonull");
		eq(null + "hello", "nullhello");

		var x = { hello:"world", val:5 };
		var xs = "" + x;
		// Output should contain hello followed by world, and val followed by 5.
		// The order of fields and operator between key and value remain unspecified.
		var h = xs.indexOf("hello");
		t(h != -1);
		t(xs.indexOf("world", h) != -1);
		h = xs.indexOf("val");
		t(h != -1);
		t(xs.indexOf("5", h) != -1);
		eq(x + "", xs);

		// Let's just make sure this is not 10 on any platform.
		eq(5 + "5", "55");
		eq("5" + 5, "55");
		eq("5" + 5.1, "55.1");
		
		// Some precedence checks.
		eq(1 + 1 + 1 + 1 + "1", "41");
		eq("1" + 1 + 1 + 1 + 1, "11111");
		eq(1 + 1 + "1" + 1 * 2, "212");
		
		// Brackets around array values should not be stripped.
		var x = [1, "hello"];
		eq("" + x, "[1, hello]");
		eq(x + "", "" + x);

		// This is also true for iterables that are arrays.
		var x:Iterable<Dynamic> = [1, "hello"];
		eq("" + x, "[1, hello]");
		eq(x + "", "" + x);		
		
		// I don't think this should throw an exception on PHP.
		try {
			"" + x.iterator();
		} catch (e:Dynamic)	{
			Test.report("Could not convert Iterator to String");
		}
		
		// This also seems rather odd on some platforms.
		var x = ["4", 1];
		t(Std.is(x[0], String));
		t(Std.is(x[0] + x[0], String));
		t(Std.is(x[1] + x[1], Int));
		t(Std.is(x[0] + x[1], String));		
	}

	function testMath() {
		eq( Std.int(-1.7), -1 );
		eq( Std.int(-1.2), -1 );
		eq( Std.int(1.7), 1 );
		eq( Std.int(1.2), 1 );
		eq( Std.int(-0.7), 0 );
		eq( Std.int(-0.2), 0 );
		eq( Std.int(0.7), 0 );
		eq( Std.int(0.2), 0 );

		eq( Math.floor(-1.7), -2 );
		eq( Math.floor(-1.5), -2 );
		eq( Math.floor(-1.2), -2 );
		eq( Math.floor(1.7), 1 );
		eq( Math.floor(1.5), 1 );
		eq( Math.floor(1.2), 1 );
		eq( Math.ceil(-1.7), -1 );
		eq( Math.ceil(-1.5), -1 );
		eq( Math.ceil(-1.2), -1 );
		eq( Math.ceil(1.7), 2 );
		eq( Math.ceil(1.5), 2 );
		eq( Math.ceil(1.2), 2 );
		eq( Math.round(-1.7), -2 );
		eq( Math.round(-1.5), -1 );
		eq( Math.round(-1.2), -1 );
		eq( Math.round(1.7), 2 );
		eq( Math.round(1.5), 2 );
		eq( Math.round(1.2), 1 );

		// overflows might occurs depending on the platform
		unspec(function() Std.int(-10000000000.7));
		unspec( function() Math.floor(-10000000000.7) );
		unspec( function() Math.ceil(-10000000000.7) );
		unspec( function() Math.round(-10000000000.7) );
		// should still give a proper result for lower bits
		eq( Std.int(-10000000000.7) & 0xFFFFFF, 15997952 );
		eq( Math.floor(-10000000000.7) & 0xFFFFFF, 15997951 );
		eq( Math.ceil(-10000000000.7) & 0xFFFFFF, 15997952 );
		eq( Math.round(-10000000000.7) & 0xFFFFFF, 15997951 );
	}

	function testParse() {
		eq( Std.parseInt("0"), 0 );
		eq( Std.parseInt("   5"), 5 );
		eq( Std.parseInt("0001"), 1 );
		eq( Std.parseInt("0010"), 10 );
		eq( Std.parseInt("100"), 100 );
		eq( Std.parseInt("-100"), -100 );
		eq( Std.parseInt("100x123"), 100 );
		eq( Std.parseInt(""), null );
		eq( Std.parseInt("abcd"), null );
		eq( Std.parseInt("a10"), null );
		eq( Std.parseInt(null), null );
		eq( Std.parseInt("0xFF"), 255 );
		eq( Std.parseInt("0x123"), 291 );
		unspec(function() Std.parseInt("0xFG"));

		eq( Std.parseFloat("0"), 0. );
		eq( Std.parseFloat("   5.3"), 5.3 );
		eq( Std.parseFloat("0001"), 1. );
		eq( Std.parseFloat("100.45"), 100.45 );
		eq( Std.parseFloat("-100.01"), -100.01 );
		eq( Std.parseFloat("100x123"), 100. );
		t( Math.isNaN(Std.parseFloat("")) );
		t( Math.isNaN(Std.parseFloat("abcd")) );
		t( Math.isNaN(Std.parseFloat("a10")) );
		t( Math.isNaN(Std.parseFloat(null)) );
		eq( Std.parseFloat("5.3 "), 5.3 );
		eq( Std.parseFloat("0.0"), 0. );
		eq( Std.parseFloat("5.3 1"), 5.3 );
	}

	function testStringTools() {
		eq( StringTools.hex(0xABCDEF,7), "0ABCDEF" );
		eq( StringTools.hex(-1,8), "FFFFFFFF" );
		eq( StringTools.hex(-481400000,8), "E34E6B40" );
	}
	
	function testCCA() {
		var str = "abc";
		eq( StringTools.fastCodeAt(str, 0), "a".code );
		eq( StringTools.fastCodeAt(str, 1), "b".code );
		eq( StringTools.fastCodeAt(str, 2), "c".code );
		f( StringTools.isEOF(StringTools.fastCodeAt(str, 2)) );
		t( StringTools.isEOF(StringTools.fastCodeAt(str, 3)) );
		
		t( StringTools.isEOF(StringTools.fastCodeAt("", 0)) );
	}
	
	function testHash() {
		var h = new Hash<Null<Int>>();
		h.set("x", -1);
		h.set("abcd", 8546);
		eq( h.get("x"), -1);
		eq( h.get("abcd"), 8546 );
		eq( h.get("e"), null );

		var k = Lambda.array(h);
		k.sort(Reflect.compare);
		eq( k.join("#"), "-1#8546" );
		
		var k = Lambda.array( { iterator : h.keys } );
		k.sort(Reflect.compare);
		eq( k.join("#"), "abcd#x" );
		
		t( h.exists("x") );
		t( h.exists("abcd") );
		f( h.exists("e") );
		h.remove("abcd");
		t( h.exists("x") );
		f( h.exists("abcd") );
		f( h.exists("e") );
		eq( h.get("abcd"), null);
		
		h.set("x", null);
		t( h.exists("x") );
		t( h.remove("x") );
		f( h.remove("x") );
	}

	function testIntHash() {
		var h = new IntHash<Null<Int>>();
		h.set(0, -1);
		h.set(-4815, 8546);
		eq( h.get(0), -1);
		eq( h.get(-4815), 8546 );
		eq( h.get(456), null );

		var k = Lambda.array(h);
		k.sort(Reflect.compare);
		eq( k.join("#"), "-1#8546" );
		
		var k = Lambda.array( { iterator : h.keys } );
		k.sort(Reflect.compare);
		eq( k.join("#"), "-4815#0" );
		
		t( h.exists(0) );
		t( h.exists(-4815) );
		f( h.exists(456) );
		h.remove(-4815);
		t( h.exists(0) );
		f( h.exists(-4815) );
		f( h.exists(456) );
		eq( h.get( -4815), null);
		
		h.set(65, null);
		t( h.exists(65) );
		t( h.remove(65) );
		f( h.remove(65) );
		
		var h = new IntHash();
		h.set(1, ['a', 'b']);
		t( h.exists(1) );
		t( h.remove(1) );
		f( h.remove(1) );
	}
}
