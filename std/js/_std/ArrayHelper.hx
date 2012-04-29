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

class ArrayHelper
{
	public static dynamic function remove<T>( a : Array<T>, x : T ) : Bool
	{
		// dummy, will be overridden by __init__
		return false;
	}

	public static function get_iterator<T>( a : Array<T> ) : Iterator<T>
	{
		untyped {
			return {
				cur : 0,
				arr : a,
				hasNext : function() {
					return __this__.cur < __this__.arr.length;
				},
				next : function() {
				   return __this__.arr[__this__.cur++];
				}
			}
		}
	}

	public static function iter<T>( it : Iterable<T> ) : Void -> Iterator<T>
	{
		if (Std.is(it, Array)) {
			return function() return ArrayHelper.get_iterator(cast it);
		} else {
			return it.iterator;
		}
	}

	public static function __init__()
	{
		ArrayHelper.remove = if(untyped Array.prototype.indexOf)
			untyped function(a, x) {
				var idx = a.indexOf(x);
				if(idx == -1) return false;
				a.splice(idx, 1);
				return true;
			}
		else untyped function(a, x) {
			var i = 0;
			var l = a.length;
			while (i < l) {
				if (a[i] == x) {
					a.splice(i, 1);
					return true;
				}
				i++;
			}
			return false;
		};
	}
}
