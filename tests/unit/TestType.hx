package unit;
import unit.MyEnum;
import unit.MyClass;

class TestType extends Test {

	static inline function u( s : String ) : String {
		#if flash
		return untyped __unprotect__(s);
		#else
		return s;
		#end
	}
	
	@:macro static function typedAs(actual:haxe.macro.Expr, expected:haxe.macro.Expr) {
		var tExpected = haxe.macro.Context.typeof(expected);
		var tActual = haxe.macro.Context.typeof(actual);
		return haxe.macro.Context.parse("{Test.count++; eq('" +Std.string(tActual) + "', '" +Std.string(tExpected) + "');}", haxe.macro.Context.currentPos());
	}
	
	@:macro static function typeError(e:haxe.macro.Expr) {
		var result = try {
			haxe.macro.Context.typeof(e);
			"false";
		} catch (e:Dynamic) "true";
		return { pos: haxe.macro.Context.currentPos(), expr: haxe.macro.Expr.ExprDef.EConst(haxe.macro.Expr.Constant.CIdent(result)) };
	}

	public function testType() {
		var name = u("unit")+"."+u("MyClass");
		eq( Type.resolveClass(name), unit.MyClass );
		eq( Type.getClassName(unit.MyClass), name );
		eq( Type.getClassFields(unit.MyClass).length , 0 );
	}

	public function testFields() {
		var sfields = Type.getClassFields(unit.MySubClass);
		eq( sfields.length , 1 );
		eq( sfields[0], u("XXX") );

		var fields = [u("add"),u("get"),u("intValue"),u("ref"),u("set"),u("stringValue"),u("val")];
		var fl = Type.getInstanceFields(unit.MyClass);
		fl.sort(Reflect.compare);
		eq( fl.join("|"), fields.join("|") );
		var fl = Type.getInstanceFields(unit.MySubClass);
		fl.sort(Reflect.compare);
		eq( fl.join("|"), fields.join("|") );
	}

	public function testEnumEq() {
		t( Type.enumEq(null,null) );
		f( Type.enumEq(A,null) );
		f( Type.enumEq(null,D(A)) );

		t( Type.enumEq(A,A) );
		t( Type.enumEq(B,B) );
		f( Type.enumEq(A,B) );

		t( Type.enumEq(C(1,"hello"),C(1,"hello")) );
		f( Type.enumEq(C(1,"hello"),C(1,"hellox")) );

		t( Type.enumEq(D(A),D(A)) );
		f( Type.enumEq(D(A),D(B)) );

	}
	
	function testPossibleBug() {
		var c = Type.getEnumConstructs(MyEnum);
		var old = c[0];
		c[0] = "modified";
		eq( Type.getEnumConstructs(MyEnum)[0], old );
		
		var i = Type.getInstanceFields(TestType);
		var old = i[0];
		i[0] = "modified";
		eq( Type.getInstanceFields(TestType)[0], old );
		
		var i = Type.getClassFields(TestType);
		var old = i[0];
		i[0] = "modified";
		eq( Type.getClassFields(TestType)[0], old );
		
		// we don't check for Type.enumParameters modifications :
		// we want it to be as fast as possible even if it references
		// the current enum - since it's not cachable
	}
	
	function testAllField() {
		eq( Type.allEnums(MyEnum).join("#"), "A#B" );
	}
	
	function testWiderVisibility() {
		var c = new MyClass.MyChild1();
		eq(12, c.a());
		
		var mc2 = new MyChild2();
		eq(21, mc2.test1(new MyChild1()));
		eq(19, mc2.test2(new MyChild1()));
	}
	
	function testUnifyMin() {
		#if !macro

		// array
		
		var ti1:Array<I1>;
		var tbase:Array<Base>;
		var tpbase:Array<PClassBase<Float>>;
		#if (flash9 || cpp)
		var tnullbool:Array<Null<Bool>>;
		var tnullbase:Array<Null<Base>>;
		#else
		var tnullbool:Array<Bool>;
		var tnullbase:Array<Base>;
		#end
		var tchild1:Array<Child1>;
		var ts:Array<{s:String}>;
		
		typedAs([new Child1(), new Child2()], tbase);
		typedAs([new Child1(), new Child2(), new Base()], tbase);
		typedAs([new Child1(), new Child2_1(), new Base()], tbase);	
		typedAs([new Child2(), new Unrelated()], ti1);
		typedAs([new Child2_1(), new Unrelated()], ti1);

		typedAs([new ClassI2(), new Child2()], ti1);
		typedAs([new CI1(), new CI2()], tbase);
		typedAs([new CII1(), new CII2()], tbase);
		
		typedAs([new PClass1(), new PClass2(2.0)], tpbase);
		
		typedAs([null, false], tnullbool);
		typedAs([false, null], tnullbool);
		typedAs([null, new Base()], tnullbase);
		//typedAs([new Base(), null], tnullbase); // TODO: this fails on flash9 and cpp
		typedAs([new Base()], tbase);
		typedAs([new Base(), new Child1()], tbase);
		typedAs([new Child1(), new Base()], tbase);
		typedAs([new Child1(), new Child1()], tchild1);
		typedAs([ { s:"foo" }, new Unrelated()], ts);
		typedAs([new Unrelated(), { s:"foo" } ], ts);

		// if
		
		var tbase:Base;
		var ti1:I1;
		#if (flash9 || cpp)
		var tnullbool:Null<Bool>;
		#else
		var tnullbool:Bool;
		#end
		var ts: { s:String };
		
		typedAs(if (false) new Child1(); else new Child2(), tbase);
		typedAs(
			if (false) new Child1();
			else if (true) new Child2();
			else new Base(), tbase);
		typedAs(
			if (false) new Child1();
			else if (true) new Child2_1();
			else new Base(), tbase);
		typedAs(if (false) new Child2(); else new Unrelated(), ti1);
		typedAs(if (false) new Child2_1(); else new Unrelated(), ti1);
		
		typedAs(if (false) null; else false, tnullbool);
		typedAs(if (false) true; else null, tnullbool);
		typedAs(if (false) new Unrelated(); else {s:"foo"}, ts);
		typedAs(if (false) { s:"foo" }; else new Unrelated(), ts);
		
		//switch
		
		typedAs(switch(false) { case true: new Child1(); case false: new Child2(); }, tbase);
		typedAs(switch(1) { case 0: new Child1(); case 1: new Child2(); case 2: new Base(); }, tbase);
		typedAs(switch(1) { case 0: new Child1(); case 1: new Child2_1(); default: new Base(); }, tbase);
		typedAs(switch(false) { case true: new Child2(); case false: new Unrelated(); }, ti1);
		typedAs(switch(false) { case true: new Child2_1(); case false: new Unrelated(); }, ti1);
		
		typedAs(switch(false) { case true: null; default: false; }, tnullbool);
		typedAs(switch(false) { case true: true; default: null; }, tnullbool);
		typedAs(switch(false) { case true: new Unrelated(); default: {s:"foo"}; }, ts);
		typedAs(switch(false) { case true: { s:"foo" }; default: new Unrelated(); }, ts);
		
		#if flash9
		typedAs(function() { return 0; var v:UInt = 0; return v; } (), 1);
		#end

		#end
	}

	function testCallback()
	{
		var func = function(a:Int, b:String, c:Float) return a;

		#if !macro
		var tstringfloat = function(b:String, c:Float) return 0;
		var tfloat = function(c:Float) return 0;
		var tvoid = function() return 0;
		var tintstring = function(a:Int, b:String) return 0;
		var tintfloat = function(a:Int, c:Float) return 0;
		var tint = function(a:Int) return 0;	
		var tstring = function(b:String) return 0;	

		// all missing
		
		typedAs(callback(func), func);
		typedAs(callback(func, _), func);
		typedAs(callback(func, _, _), func);
		typedAs(callback(func, _, _, _), func);

		// all given
		
		typedAs(callback(func, 22, "2", 13), tvoid);

		// last missing
		
		typedAs(callback(func, 22, "2"), tfloat);
		typedAs(callback(func, 22, "2", _), tfloat);
		
		// first given
		
		typedAs(callback(func, 22), tstringfloat);
		typedAs(callback(func, 22, _), tstringfloat);
		typedAs(callback(func, 22, _, _), tstringfloat);
		
		// mixed
		
		typedAs(callback(func, _, _, 12), tintstring);
		typedAs(callback(func, _, "22", _), tintfloat);
		typedAs(callback(func, _, "22", 12), tint);
		typedAs(callback(func, 12, _, 12), tstring);
		
		#end
		
		// values
		
		eq(1, callback(func)(1, "2", 3));
		eq(2, callback(func, 2)("2", 3));
		eq(2, callback(func, 2, "3")(3));
		eq(2, callback(func, 2, "3", 4)());
		
		eq(1, callback(func, _, "2", 3)(1));
		eq(1, callback(func, _, "2")(1, 3));
		eq(1, callback(func, _)(1, "2", 3));
		
		eq(1, callback(func, _, "2", _)(1, 2));
		
		eq(1, callback(callback(func), _, "2", 3)(1));
		eq(1, callback(callback(func, 1), "2", 3)());
		eq(1, callback(callback(func, 1, _), "2")(3));
		eq(1, callback(callback(func, _, "2"), 1)(3));
		
		var a = 5;
		var b = "foo";
		var cb = callback(func, a);
		a = 6;
		func = function(a,b,c):Int return throw "error";
		eq(5, cb(b, 0));
		
		var optfunc = function(a:Int, b:Int, ?c:Int = 2) return a + b + c;
		eq(6, callback(optfunc, 1)(3));
		eq(6, callback(optfunc, 1, 3)());
		
		eq(7, callback(optfunc, _, _, _)(1, 2, 4));
		eq(7, callback(optfunc, _, 2, _)(1, 4));
		
		var foo = function ( x : Int, ?p : haxe.PosInfos ) { return "foo" + x; }
		var f : Void -> String = callback(foo, 0);
 		eq("foo0", f());
	}
	
	function testConstantAnonCovariance()
	{
		#if !macro
		var a: { v:Float };
		var b:Dynamic = "bar";
		f(typeError(a = { v:0.2 } ));
		f(typeError(a = { v:0 } ));
		typedAs(a = { v: 0 }, a);
		typedAs(a = { v: 0.2 }, a);
		t(typeError(a = { v: "foo" } ));
		f(typeError(a = { v: untyped "foo" } ));
		f(typeError(a = { v: b } ));
		f(typeError( { var b: { v:Dynamic } = { v: "foo" };} ));
		t(typeError( { var b: { v:Int } = { v: 1.2 }; } ));
		t(typeError( { var b: { v:Int } = { v:0, w:"foo" }; }));
		t(typeError( { var b: { v:Int } = { v:0, v:2 }; } ));
		t(typeError( { var b: { v:Int, w:String } = { v:0 }; } ));
		#end
	}
	
	function testCovariantReturn()
	{
		#if !macro
		var b:Base = null;
		var c1:Child1 = null;
		var c2_1:Child2_1 = null;
		
		var c = new Cov2();
		typedAs(c.covariant(), c1);
		t(Std.is(c.covariant(), Child1));
		t(Std.is(cast(c, Cov1).covariant(), Child1));
		
		// base class reference
		var br:Cov1 = c;
		typedAs(br.covariant(), b);
		t(Std.is(br.covariant(), Child1));
		
		// interface reference
		var ir:CovI = c;
		typedAs(ir.covariant(), b);
		t(Std.is(ir.covariant(), Child1));
		
		// dynamic
		var dr:Dynamic = c;
		t(Std.is(dr.covariant(), Child1));
		
		// interface covariance
		var c3 = new Cov3();
		typedAs(c3.covariant(), c2_1);
		t(Std.is(c3.covariant(), Child2_1));
		#end
	}
	
	function testContravariantArgs()
	{
		#if !macro
		var b = function(arg:Base):Void { };
		var c1 = function(arg:Child1):Void { };
		
		var c = new Ctrv2();
		typedAs(c.contravariant, b);
		typedAs(cast (c, Ctrv1).contravariant, c1);
		#end
	}
}
