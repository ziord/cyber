/*  tccdefs.h (converted, do not edit this file)

    Nothing is defined before this file except target machine, target os
    and the few things related to option settings in tccpp.c:tcc_predefs().

    This file is either included at runtime as is, or converted and
    included as C-strings at compile-time (depending on CONFIG_TCC_PREDEFS).

    Note that line indent matters:

    - in lines starting at column 1, platform macros are replaced by
      corresponding TCC target compile-time macros.  See conftest.c for
      the list of platform macros supported in lines starting at column 1.

    - only lines indented >= 4 are actually included into the executable,
      check tccdefs_.h.
*/

#if PTR_SIZE == 4
    /* 32bit systems. */
#if defined TARGETOS_OpenBSD
    "#define __SIZE_TYPE__ unsigned long\n"
    "#define __PTRDIFF_TYPE__ long\n"
#else
    "#define __SIZE_TYPE__ unsigned int\n"
    "#define __PTRDIFF_TYPE__ int\n"
#endif
    "#define __ILP32__ 1\n"
    "#define __INT64_TYPE__ long long\n"
#elif LONG_SIZE == 4
    /* 64bit Windows. */
    "#define __SIZE_TYPE__ unsigned long long\n"
    "#define __PTRDIFF_TYPE__ long long\n"
    "#define __LLP64__ 1\n"
    "#define __INT64_TYPE__ long long\n"
#else
    /* Other 64bit systems. */
    "#define __SIZE_TYPE__ unsigned long\n"
    "#define __PTRDIFF_TYPE__ long\n"
    "#define __LP64__ 1\n"
# if defined TARGETOS_Linux
    "#define __INT64_TYPE__ long\n"
# else /* APPLE, BSD */
    "#define __INT64_TYPE__ long long\n"
# endif
#endif
    "#define __SIZEOF_INT__ 4\n"
    "#define __INT_MAX__ 0x7fffffff\n"
#if LONG_SIZE == 4
    "#define __LONG_MAX__ 0x7fffffffL\n"
#else
    "#define __LONG_MAX__ 0x7fffffffffffffffL\n"
#endif
    "#define __SIZEOF_LONG_LONG__ 8\n"
    "#define __LONG_LONG_MAX__ 0x7fffffffffffffffLL\n"
    "#define __CHAR_BIT__ 8\n"
    "#define __ORDER_LITTLE_ENDIAN__ 1234\n"
    "#define __ORDER_BIG_ENDIAN__ 4321\n"
    "#define __BYTE_ORDER__ __ORDER_LITTLE_ENDIAN__\n"
#if defined TCC_TARGET_PE
    "#define __WCHAR_TYPE__ unsigned short\n"
    "#define __WINT_TYPE__ unsigned short\n"
#elif defined TARGETOS_Linux
    "#define __WCHAR_TYPE__ int\n"
    "#define __WINT_TYPE__ unsigned int\n"
#else
    "#define __WCHAR_TYPE__ int\n"
    "#define __WINT_TYPE__ int\n"
#endif

    "#if __STDC_VERSION__==201112L\n"
    "#define __STDC_NO_ATOMICS__ 1\n"
    "#define __STDC_NO_COMPLEX__ 1\n"
    "#define __STDC_NO_THREADS__ 1\n"
#if !defined TCC_TARGET_PE
    "#define __STDC_UTF_16__ 1\n"
    "#define __STDC_UTF_32__ 1\n"
#endif
    "#endif\n"

#if defined TCC_TARGET_PE
    "#define __declspec(x) __attribute__((x))\n"
    "#define __cdecl\n"

#elif defined TARGETOS_FreeBSD
    "#define __GNUC__ 9\n"
    "#define __GNUC_MINOR__ 3\n"
    "#define __GNUC_PATCHLEVEL__ 0\n"
    "#define __GNUC_STDC_INLINE__ 1\n"
    "#define __NO_TLS 1\n"
    "#define __RUNETYPE_INTERNAL 1\n"
# if PTR_SIZE == 8
    /* FIXME, __int128_t is used by setjump */
    "#define __int128_t struct{unsigned char _dummy[16]__attribute((aligned(16)));}\n"
    "#define __SIZEOF_SIZE_T__ 8\n"
    "#define __SIZEOF_PTRDIFF_T__ 8\n"
#else
    "#define __SIZEOF_SIZE_T__ 4\n"
    "#define __SIZEOF_PTRDIFF_T__ 4\n"
# endif

#elif defined TARGETOS_FreeBSD_kernel

#elif defined TARGETOS_NetBSD
    "#define __GNUC__ 4\n"
    "#define __GNUC_MINOR__ 1\n"
    "#define __GNUC_PATCHLEVEL__ 0\n"
    "#define _Pragma(x)\n"
    "#define __ELF__ 1\n"
#if defined TCC_TARGET_ARM64
    "#define _LOCORE\n" /* avoids usage of __asm */
#endif

#elif defined TARGETOS_OpenBSD
    "#define __GNUC__ 4\n"
    "#define _ANSI_LIBRARY 1\n"

#elif defined TCC_TARGET_MACHO
    /* emulate APPLE-GCC to make libc's headerfiles compile: */
    "#define __GNUC__ 4\n"   /* darwin emits warning on GCC<4 */
    "#define __APPLE_CC__ 1\n" /* for <TargetConditionals.h> */
    "#define __LITTLE_ENDIAN__ 1\n"
    "#define _DONT_USE_CTYPE_INLINE_ 1\n"
    /* avoids usage of GCC/clang specific builtins in libc-headerfiles: */
    "#define __FINITE_MATH_ONLY__ 1\n"
    "#define _FORTIFY_SOURCE 0\n"

#elif defined TARGETOS_ANDROID
    "#define BIONIC_IOCTL_NO_SIGNEDNESS_OVERLOAD\n"
    "#define __PRETTY_FUNCTION__ __FUNCTION__\n"
    "#define __has_builtin(x) 0\n"
    "#define _Nonnull\n"
    "#define _Nullable\n"

#else
    /* Linux */

#endif
    /* Some derived integer types needed to get stdint.h to compile correctly on some platforms */
#ifndef TARGETOS_NetBSD
    "#define __UINTPTR_TYPE__ unsigned __PTRDIFF_TYPE__\n"
    "#define __INTPTR_TYPE__ __PTRDIFF_TYPE__\n"
#endif
    "#define __INT32_TYPE__ int\n"

#if !defined TCC_TARGET_PE
    /* glibc defines */
    "#define __REDIRECT(name,proto,alias) name proto __asm__(#alias)\n"
    "#define __REDIRECT_NTH(name,proto,alias) name proto __asm__(#alias)__THROW\n"
#endif

    /* skip __builtin... with -E */
    "#ifndef __TCC_PP__\n"

    "#define __builtin_offsetof(type,field) ((__SIZE_TYPE__)&((type*)0)->field)\n"
    "#define __builtin_extract_return_addr(x) x\n"
#if !defined TARGETOS_Linux && !defined TCC_TARGET_PE
    /* used by math.h */
    "#define __builtin_huge_val() 1e500\n"
    "#define __builtin_huge_valf() 1e50f\n"
    "#define __builtin_huge_vall() 1e5000L\n"
# if defined TCC_TARGET_MACHO
    "#define __builtin_nanf(ignored_string) (0.0F/0.0F)\n"
    /* used by floats.h to implement FLT_ROUNDS C99 macro. 1 == to nearest */
    "#define __builtin_flt_rounds() 1\n"
    /* used by _fd_def.h */
    "#define __builtin_bzero(p,ignored_size) bzero(p,sizeof(*(p)))\n"
# else
    "#define __builtin_nanf(ignored_string) (0.0F/0.0F)\n"
# endif
#endif

    /* __builtin_va_list */
#if defined TCC_TARGET_X86_64
#if !defined TCC_TARGET_PE
    /* GCC compatible definition of va_list. */
    /* This should be in sync with the declaration in our lib/libtcc1.c */
    "typedef struct{\n"
    "unsigned gp_offset,fp_offset;\n"
    "union{\n"
    "unsigned overflow_offset;\n"
    "char*overflow_arg_area;\n"
    "};\n"
    "char*reg_save_area;\n"
    "}__builtin_va_list[1];\n"

    "void*__va_arg(__builtin_va_list ap,int arg_type,int size,int align);\n"
    "#define __builtin_va_start(ap,last) (*(ap)=*(__builtin_va_list)((char*)__builtin_frame_address(0)-24))\n"
    "#define __builtin_va_arg(ap,t) (*(t*)(__va_arg(ap,__builtin_va_arg_types(t),sizeof(t),__alignof__(t))))\n"
    "#define __builtin_va_copy(dest,src) (*(dest)=*(src))\n"

#else /* _WIN64 */
    "typedef char*__builtin_va_list;\n"
    "#define __builtin_va_arg(ap,t) ((sizeof(t)>8||(sizeof(t)&(sizeof(t)-1)))?**(t**)((ap+=8)-8):*(t*)((ap+=8)-8))\n"
#endif

#elif defined TCC_TARGET_ARM
    "typedef char*__builtin_va_list;\n"
    "#define _tcc_alignof(type) ((int)&((struct{char c;type x;}*)0)->x)\n"
    "#define _tcc_align(addr,type) (((unsigned)addr+_tcc_alignof(type)-1)&~(_tcc_alignof(type)-1))\n"
    "#define __builtin_va_start(ap,last) (ap=((char*)&(last))+((sizeof(last)+3)&~3))\n"
    "#define __builtin_va_arg(ap,type) (ap=(void*)((_tcc_align(ap,type)+sizeof(type)+3)&~3),*(type*)(ap-((sizeof(type)+3)&~3)))\n"

#elif defined TCC_TARGET_ARM64
#if defined TCC_TARGET_MACHO
    "typedef struct{\n"
    "void*__stack;\n"
    "}__builtin_va_list;\n"

#else
    "typedef struct{\n"
    "void*__stack,*__gr_top,*__vr_top;\n"
    "int __gr_offs,__vr_offs;\n"
    "}__builtin_va_list;\n"

#endif
#elif defined TCC_TARGET_RISCV64
    "typedef char*__builtin_va_list;\n"
    "#define __va_reg_size (__riscv_xlen>>3)\n"
    "#define _tcc_align(addr,type) (((unsigned long)addr+__alignof__(type)-1)&-(__alignof__(type)))\n"
    "#define __builtin_va_arg(ap,type) (*(sizeof(type)>(2*__va_reg_size)?*(type**)((ap+=__va_reg_size)-__va_reg_size):(ap=(va_list)(_tcc_align(ap,type)+(sizeof(type)+__va_reg_size-1)&-__va_reg_size),(type*)(ap-((sizeof(type)+__va_reg_size-1)&-__va_reg_size)))))\n"

#else /* TCC_TARGET_I386 */
    "typedef char*__builtin_va_list;\n"
    "#define __builtin_va_start(ap,last) (ap=((char*)&(last))+((sizeof(last)+3)&~3))\n"
    "#define __builtin_va_arg(ap,t) (*(t*)((ap+=(sizeof(t)+3)&~3)-((sizeof(t)+3)&~3)))\n"

#endif
    "#define __builtin_va_end(ap) (void)(ap)\n"
    "#ifndef __builtin_va_copy\n"
    "#define __builtin_va_copy(dest,src) (dest)=(src)\n"
    "#endif\n"

    /* TCC BBUILTIN AND BOUNDS ALIASES */
    "#ifdef __leading_underscore\n"
    "#define __RENAME(X) __asm__(\"_\"X)\n"
    "#else\n"
    "#define __RENAME(X) __asm__(X)\n"
    "#endif\n"

    "#ifdef __BOUNDS_CHECKING_ON\n"
    "#define __BUILTINBC(ret,name,params) ret __builtin_##name params __RENAME(\"__bound_\"#name);\n"
    "#define __BOUND(ret,name,params) ret name params __RENAME(\"__bound_\"#name);\n"
    "#else\n"
    "#define __BUILTINBC(ret,name,params) ret __builtin_##name params __RENAME(#name);\n"
    "#define __BOUND(ret,name,params)\n"
    "#endif\n"
#ifdef TCC_TARGET_PE
    "#define __BOTH __BOUND\n"
    "#define __BUILTIN(ret,name,params)\n"
#else
    "#define __BOTH(ret,name,params) __BUILTINBC(ret,name,params)__BOUND(ret,name,params)\n"
    "#define __BUILTIN(ret,name,params) ret __builtin_##name params __RENAME(#name);\n"
#endif

    "__BOTH(void*,memcpy,(void*,const void*,__SIZE_TYPE__))\n"
    "__BOTH(void*,memmove,(void*,const void*,__SIZE_TYPE__))\n"
    "__BOTH(void*,memset,(void*,int,__SIZE_TYPE__))\n"
    "__BOTH(int,memcmp,(const void*,const void*,__SIZE_TYPE__))\n"
    "__BOTH(__SIZE_TYPE__,strlen,(const char*))\n"
    "__BOTH(char*,strcpy,(char*,const char*))\n"
    "__BOTH(char*,strncpy,(char*,const char*,__SIZE_TYPE__))\n"
    "__BOTH(int,strcmp,(const char*,const char*))\n"
    "__BOTH(int,strncmp,(const char*,const char*,__SIZE_TYPE__))\n"
    "__BOTH(char*,strcat,(char*,const char*))\n"
    "__BOTH(char*,strncat,(char*,const char*,__SIZE_TYPE__))\n"
    "__BOTH(char*,strchr,(const char*,int))\n"
    "__BOTH(char*,strrchr,(const char*,int))\n"
    "__BOTH(char*,strdup,(const char*))\n"
#if defined TCC_ARM_EABI
    "__BOUND(void*,__aeabi_memcpy,(void*,const void*,__SIZE_TYPE__))\n"
    "__BOUND(void*,__aeabi_memmove,(void*,const void*,__SIZE_TYPE__))\n"
    "__BOUND(void*,__aeabi_memmove4,(void*,const void*,__SIZE_TYPE__))\n"
    "__BOUND(void*,__aeabi_memmove8,(void*,const void*,__SIZE_TYPE__))\n"
    "__BOUND(void*,__aeabi_memset,(void*,int,__SIZE_TYPE__))\n"
#endif

#if defined TARGETOS_Linux || defined TCC_TARGET_MACHO // HAVE MALLOC_REDIR
    "#define __MAYBE_REDIR __BUILTIN\n"
#else
    "#define __MAYBE_REDIR __BOTH\n"
#endif
    "__MAYBE_REDIR(void*,malloc,(__SIZE_TYPE__))\n"
    "__MAYBE_REDIR(void*,realloc,(void*,__SIZE_TYPE__))\n"
    "__MAYBE_REDIR(void*,calloc,(__SIZE_TYPE__,__SIZE_TYPE__))\n"
    "__MAYBE_REDIR(void*,memalign,(__SIZE_TYPE__,__SIZE_TYPE__))\n"
    "__MAYBE_REDIR(void,free,(void*))\n"
#if defined TCC_TARGET_I386 || defined TCC_TARGET_X86_64
    "__BOTH(void*,alloca,(__SIZE_TYPE__))\n"
#else
    "__BUILTIN(void*,alloca,(__SIZE_TYPE__))\n"
#endif
    "__BUILTIN(void,abort,(void))\n"
    "__BOUND(void,longjmp,())\n"
#if !defined TCC_TARGET_PE
    "__BOUND(void*,mmap,())\n"
    "__BOUND(int,munmap,())\n"
#endif
    "#undef __BUILTINBC\n"
    "#undef __BUILTIN\n"
    "#undef __BOUND\n"
    "#undef __BOTH\n"
    "#undef __MAYBE_REDIR\n"
    "#undef __RENAME\n"

    "#endif\n" /* ndef __TCC_PP__ */
