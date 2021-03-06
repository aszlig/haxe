import haxe.lang.Function;
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

/**
	The Reflect API is a way to manipulate values dynamicly through an
	abstract interface in an untyped manner. Use with care.
**/
@:core_api class Reflect {

	/**
		Tells if an object has a field set. This doesn't take into account the object prototype (class methods).
	**/
	@:functionBody('
		if (o is haxe.lang.IHxObject)
		return ((haxe.lang.IHxObject) o).__hx_getField(field, haxe.lang.FieldLookup.hash(field), false, false, true) != haxe.lang.Runtime.undefined;
		
		return haxe.lang.Runtime.slowHasField(o, field);
	')
	public static function hasField( o : Dynamic, field : String ) : Bool
	{
		return false;
	}

	/**
		Returns the field of an object, or null if [o] is not an object or doesn't have this field.
	**/
	@:functionBody('
		if (o is haxe.lang.IHxObject)
		return ((haxe.lang.IHxObject) o).__hx_getField(field, haxe.lang.FieldLookup.hash(field), false, false, false);
		
		return haxe.lang.Runtime.slowGetField(o, field, false);
	')
	public static function field( o : Dynamic, field : String ) : Dynamic
	{
		return null;
	}


	/**
		Set an object field value.
	**/
	@:functionBody('
		if (o is haxe.lang.IHxObject)
			((haxe.lang.IHxObject) o).__hx_setField(field, haxe.lang.FieldLookup.hash(field), false, value);
		
		 haxe.lang.Runtime.slowSetField(o, field, value);
	')
	public static function setField( o : Dynamic, field : String, value : Dynamic ) : Void
	{
		
	}
	
	/**
		Similar to field but also supports property (might be slower).
	**/
	public static function getProperty( o : Dynamic, field : String ) : Dynamic
	{
		return null;
	}

	/**
		Similar to setField but also supports property (might be slower).
	**/
	public static function setProperty( o : Dynamic, field : String, value : Dynamic ) : Void
	{
		
	}

	/**
		Call a method with the given object and arguments.
	**/
	@:functionBody('
		return ((haxe.lang.Function) func).__hx_invokeDynamic(args);
	')
	public static function callMethod( o : Dynamic, func : Dynamic, args : Array<Dynamic> ) : Dynamic
	{
		return null;
	}

	/**
		Returns the list of fields of an object, excluding its prototype (class methods).
	**/
	@:functionBody('
		if (o is haxe.lang.IHxObject)
		{
			Array<object> ret = new Array<object>();
			((haxe.lang.IHxObject) o).__hx_getFields(ret, false);
			return ret;
		} else {
			Array<object> ret = new Array<object>();
			
			if (o is System.Type)
			{
				System.Type cl = (System.Type) o;
				
				foreach(System.Reflection.FieldInfo fi in cl.GetFields(System.Reflection.BindingFlags.Static))
				{
					ret.push(fi.Name);
				}
				
				string last = null;
				foreach(System.Reflection.MethodInfo mi in cl.GetMethods(System.Reflection.BindingFlags.Static))
				{
					string name = mi.Name;
					if (last != name)
					{
						ret.push(name);
						last = name;
					}
				}
			}
			
			return ret;
		}
	')
	public static function fields( o : Dynamic ) : Array<String>
	{
		return null;
	}

	/**
		Tells if a value is a function or not.
	**/
	@:functionBody('
		return f is haxe.lang.Function;
	')
	public static function isFunction( f : Dynamic ) : Bool
	{
		return false;
	}

	/**
		Generic comparison function, does not work for methods, see [compareMethods]
	**/
	@:functionBody('
		return haxe.lang.Runtime.compare(a, b);
	')
	public static function compare<T>( a : T, b : T ) : Int
	{
		return 0;
	}

	/**
		Compare two methods closures. Returns true if it's the same method of the same instance.
	**/
	@:functionBody('
		if (f1 == f2) 
			return true;
		
		if (f1 is haxe.lang.Closure && f2 is haxe.lang.Closure)
		{
			haxe.lang.Closure f1c = (haxe.lang.Closure) f1;
			haxe.lang.Closure f2c = (haxe.lang.Closure) f2;
			
			return haxe.lang.Runtime.refEq(f1c.target, f2c.target) && f1c.field.Equals(f2c.field);
		} else if (f1 is haxe.lang.NativeMethodFunction && f2 is haxe.lang.NativeMethodFunction) {
			haxe.lang.NativeMethodFunction f1n = (haxe.lang.NativeMethodFunction) f1;
			haxe.lang.NativeMethodFunction f2n = (haxe.lang.NativeMethodFunction) f2;
			return haxe.lang.Runtime.refEq(f1n.obj, f2n.obj) && f1n.field.Equals(f2n.field);
		}
		
		return false;
	')
	public static function compareMethods( f1 : Dynamic, f2 : Dynamic ) : Bool
	{
		return false;
	}

	/**
		Tells if a value is an object or not.

	**/
	@:functionBody('
		return v is haxe.lang.DynamicObject;
	')
	public static function isObject( v : Dynamic ) : Bool
	{
		return false;
	}

	/**
		Delete an object field.
	**/
	@:functionBody('
		return (o is haxe.lang.DynamicObject && ((haxe.lang.DynamicObject) o).__hx_deleteField(f, haxe.lang.FieldLookup.hash(f)));
	')
	public static function deleteField( o : Dynamic, f : String ) : Bool
	{
		return false;
	}

	/**
		Make a copy of the fields of an object.
	**/
	public static function copy<T>( o : T ) : T
	{
		var o2 : Dynamic = {};
		for( f in Reflect.fields(o) )
			Reflect.setField(o2,f,Reflect.field(o,f));
		return cast o2;
	}

	/**
		Transform a function taking an array of arguments into a function that can
		be called with any number of arguments.
	**/
	public static function makeVarArgs( f : Array<Dynamic> -> Dynamic ) : Dynamic
	{
		return new VarArgsFunction(f);
	}

}
