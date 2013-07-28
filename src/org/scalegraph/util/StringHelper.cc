/*
 *  This file is part of the ScaleGraph project (https://sites.google.com/site/scalegraph/).
 *
 *  This file is licensed to You under the Eclipse Public License (EPL);
 *  You may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *      http://www.opensource.org/licenses/eclipse-1.0.php
 *
 *  (C) Copyright ScaleGraph Team 2011-2012.
 */
#include <x10aux/config.h>

#include <x10/lang/String.h>

#include <org/scalegraph/util/StringHelper.h>
#include <org/scalegraph/util/SString.h>

namespace org { namespace scalegraph { namespace util {

#define UTF8_CHAR_BYTES(c, bytesCount) \
	if(c.v < 0x80) bytesCount += 1; \
	else if(c.v < 0x800) bytesCount += 2; \
	else if(c.v < 0x10000) bytesCount += 3; \
	else bytesCount += 4

#define UTF8_ENCODE_CHAR(c, buffer, index) \
	if(c.v < 0x80) { \
		buffer[index++] = (((c.v      )       )       ); \
	} \
	else if(c.v < 0x800) { \
		buffer[index++] = (((c.v >>  6)       ) | 0xC0); \
		buffer[index++] = (((c.v      ) & 0x3F) | 0x80); \
	} \
	else if(c.v < 0x10000) { \
		buffer[index++] = (((c.v >> 12)       ) | 0xE0); \
		buffer[index++] = (((c.v >>  6) & 0x3F) | 0x80); \
		buffer[index++] = (((c.v      ) & 0x3F) | 0x80); \
	} \
	else { \
		buffer[index++] = (((c.v >> 18)       ) | 0xF0); \
		buffer[index++] = (((c.v >> 12) & 0x3F) | 0x80); \
		buffer[index++] = (((c.v >>  6) & 0x3F) | 0x80); \
		buffer[index++] = (((c.v      ) & 0x3F) | 0x80); \
	}

#define UTF8_CODE_LENGTH(b0, bytesCount) \
	if((b0 & 0x80) == 0x00) bytesCount += 1; \
	else if((b0 & 0xE0) == 0xC0) bytesCount += 2; \
	else if((b0 & 0xF0) == 0xE0) bytesCount += 3; \
	else bytesCount += 4

#define UTF8_DECODE_CHAR(ch, bytes, index) \
	x10_char ch; \
	int b0 = bytes[index++]; \
	if((b0 & 0x80) == 0x00) { \
		ch.v = b0; \
	} \
	else if((b0 & 0xE0) == 0xC0) { \
		int b1 = bytes[index++]; \
		ch.v =(((b0 & 0x1F) << 6) | \
			((b1 & 0x3F)     )); \
	} \
	else if((b0 & 0xF0) == 0xE0) { \
		int b1 = bytes[index++]; \
		int b2 = bytes[index++]; \
		ch.v =(((b0 & 0x0F) << 12) | \
			((b1 & 0x3F) <<  6) | \
			((b2 & 0x3F)     )); \
	} \
	else { \
		int b1 = bytes[index++]; \
		int b2 = bytes[index++]; \
		int b3 = bytes[index++]; \
		ch.v =(((b0 & 0x08) << 18) | \
			((b1 & 0x3F) << 12) | \
			((b2 & 0x3F) <<  6) | \
			((b3 & 0x3F)     )); \
	}


MemoryChunk<x10_byte> charsToUTF8_(MemoryChunk<x10_char>& chars) {
	int bytesCount = 0;
	int chars_size = chars.size();
	x10_char* chars_ptr = chars.pointer();
	for(int i = 0; i < chars_size; ++i) {
		x10_char c = chars_ptr[i];
		UTF8_CHAR_BYTES(c, bytesCount);
	}
	MemoryChunk<x10_byte> bytes = MemoryChunk<x10_byte>::_make(bytesCount + 1);
	x10_byte* bytes_ptr = bytes.pointer();
	int bytesIndex = 0;
	for(int i = 0; i < chars_size; ++i) {
		x10_char c = chars_ptr[i];
		UTF8_ENCODE_CHAR(c, bytes_ptr, bytesIndex);
	}
	bytes_ptr[bytesIndex] = 0;
	assert (bytesIndex = bytesCount);
	return bytes.subpart(0, bytesIndex);
}

int charToUTF8_(x10_char ch, MemoryChunk<x10_byte>& bytes) {
	int bytesCount = 0;
	x10_byte* bytes_ptr = bytes.pointer();
	UTF8_ENCODE_CHAR(ch, bytes_ptr, bytesCount);
	return bytesCount;
}

MemoryChunk<x10_char> UTF8ToChars_(MemoryChunk<x10_byte>& bytes) {
	x10_byte* bytes_ptr = bytes.pointer();
	int bytes_size = bytes.size();
	int charsCount = 0;
	for(int i = 0; i < bytes_size; ++charsCount) {
		int b0 = bytes_ptr[i];
		UTF8_CODE_LENGTH(b0, i);
	}
	MemoryChunk<x10_char> chars = MemoryChunk<x10_char>::_make(charsCount);
	x10_char* chars_ptr = chars.pointer();
	charsCount = 0;
	for(int i = 0; i < bytes_size; ++charsCount) {
		UTF8_DECODE_CHAR(ch, bytes_ptr, i);
		chars_ptr[charsCount] = ch;
	}
	return chars;
}

int UTF8charsCount_(MemoryChunk<x10_byte>& bytes) {
	x10_byte* bytes_ptr = bytes.pointer();
	int bytes_size = bytes.size();
	int charsCount = 0;
	for(int i = 0; i < bytes_size; ++charsCount) {
		int b0 = bytes_ptr[i];
		UTF8_CODE_LENGTH(b0, i);
	}
	return charsCount;
}

// TODO: optimize search methods

int StringIndexOf_(MemoryChunk<x10_byte>& th, x10_char ch, int from) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte buf[4];
	int bytesCount = 0;
	UTF8_ENCODE_CHAR(ch, buf, bytesCount);
	int lastIndex = size - bytesCount;
	if(bytesCount == 1) {
		for(int i = from; i <= lastIndex; ++i) {
			if(ptr[i] == buf[0]) return i;
		}
	}
	else if(bytesCount == 2) {
		for(int i = from; i <= lastIndex; ++i) {
			if((ptr[i+0] == buf[0]) &
			   (ptr[i+1] == buf[1])) return i;
		}
	}
	else if(bytesCount == 3) {
		for(int i = from; i <= lastIndex; ++i) {
			if((ptr[i+0] == buf[0]) &
			   (ptr[i+1] == buf[1]) &
			   (ptr[i+2] == buf[2])) return i;
		}
	}
	else {
		for(int i = from; i <= lastIndex; ++i) {
			if((ptr[i+0] == buf[0]) &
			   (ptr[i+1] == buf[1]) &
			   (ptr[i+2] == buf[2]) &
			   (ptr[i+3] == buf[3])) return i;
		}
	}
	return -1;
}

int StringIndexOf_(MemoryChunk<x10_byte>& th, MemoryChunk<x10_byte>& str, int from) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte* str_ptr = str.pointer();
	int str_size = str.size();
	int lastIndex = size - str_size;
	for(int i = from; i <= lastIndex; ++i) {
		if(memcmp(ptr + i, str_ptr, str_size) == 0)
			return i;
	}
	return -1;
}

int StringLastIndexOf_(MemoryChunk<x10_byte>& th, x10_char ch, int from) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte buf[4];
	int bytesCount = 0;
	UTF8_ENCODE_CHAR(ch, buf, bytesCount);
	int lastIndex = size - bytesCount;
	if(bytesCount == 1) {
		for(int i = lastIndex; i >= from; --i) {
			if(ptr[i] == buf[0]) return i;
		}
	}
	else if(bytesCount == 2) {
		for(int i = lastIndex; i >= from; --i) {
			if((ptr[i+0] == buf[0]) &
			   (ptr[i+1] == buf[1])) return i;
		}
	}
	else if(bytesCount == 3) {
		for(int i = lastIndex; i >= from; --i) {
			if((ptr[i+0] == buf[0]) &
			   (ptr[i+1] == buf[1]) &
			   (ptr[i+2] == buf[2])) return i;
		}
	}
	else {
		for(int i = lastIndex; i >= from; --i) {
			if((ptr[i+0] == buf[0]) &
			   (ptr[i+1] == buf[1]) &
			   (ptr[i+2] == buf[2]) &
			   (ptr[i+3] == buf[3])) return i;
		}
	}
	return -1;
}

int StringLastIndexOf_(MemoryChunk<x10_byte>& th, MemoryChunk<x10_byte>& str, int from) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte* str_ptr = str.pointer();
	int str_size = str.size();
	int lastIndex = size - str_size;
	for(int i = lastIndex; i >= from; --i) {
		if(memcmp(ptr + i, str_ptr, str_size) == 0)
			return i;
	}
	return -1;
}

bool StringEqual_(MemoryChunk<x10_byte>& th, MemoryChunk<x10_byte>& str) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte* str_ptr = str.pointer();
	int str_size = str.size();
	if(size != str_size) return false;
	return memcmp(ptr, str_ptr, size) == 0;
}

int StringCompare_(MemoryChunk<x10_byte>& th, MemoryChunk<x10_byte>& str) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte* str_ptr = str.pointer();
	int str_size = str.size();
	int cmp_size = size < str_size ? size : str_size;
	int cmp = memcmp(ptr, str_ptr, cmp_size);
	if(cmp == 0) cmp = size - str_size;
	return cmp;
}

bool StringStartsWith_(MemoryChunk<x10_byte>& th, MemoryChunk<x10_byte>& str) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte* str_ptr = str.pointer();
	int str_size = str.size();
	if(size < str_size) return false;
	return memcmp(ptr, str_ptr, str_size) == 0;
}

bool StringEndsWith_(MemoryChunk<x10_byte>& th, MemoryChunk<x10_byte>& str) {
	x10_byte* ptr = th.pointer();
	int size = th.size();
	x10_byte* str_ptr = str.pointer();
	int str_size = str.size();
	if(size < str_size) return false;
	x10_byte* cmp_ptr = ptr + size - str_size;
	return memcmp(cmp_ptr, str_ptr, str_size) == 0;
}

x10_byte* StringCstr_(SString& str) {
	x10_byte* ptr = str.FMGL(content).pointer();
	int size = str.FMGL(content).size();
	if(ptr[size] != 0) {
		x10_byte* old_ptr = ptr;
		MemoryChunk<x10_byte> nb = MemoryChunk<x10_byte>::_make(size+1);
		ptr = nb.pointer();
		memcpy(ptr, old_ptr, size);
		ptr[size] = 0;
		str.FMGL(content) = nb.subpart(0, size);
	}
	return ptr;
}

MemoryChunk<x10_byte> StringFromX10String(x10::lang::String* x10str) {
	x10_byte* ptr = reinterpret_cast<x10_byte*>(const_cast<char*>(x10str->c_str()));
	MemoryChunk<x10_byte> mc;
	mc._constructor(MCData_Impl<x10_byte>(ptr, ptr, x10str->length()));
	return mc;
}

#undef UTF8_CHAR_BYTES
#undef UTF8_ENCODE_CHAR
#undef UTF8_CODE_LENGTH
#undef UTF8_DECODE_CHAR

}}} // namespace org { namespace scalegraph { namespace util {

/*************************************************/
/* START of SString$TokenIterator */
#include <org/scalegraph/util/SString__TokenIterator.h>

x10aux::RuntimeType org::scalegraph::util::SString__TokenIterator<void>::rtt;

/* END of SString$TokenIterator */
/*************************************************/


