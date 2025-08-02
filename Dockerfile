FROM ubuntu:focal AS builder

RUN apt-get update && \
	DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
	build-essential autoconf automake libtool cmake file less \
	texinfo flex librsvg2-bin icoutils gperf bison ghostscript gnuplot tree \
	python3 ca-certificates git openjdk-11-jre curl nano unzip \
	&& rm -rf /var/lib/apt/lists/*

RUN git clone https://github.com/emscripten-core/emsdk.git /usr/src/emsdk
WORKDIR /usr/src/emsdk

RUN git fetch
ENV SDK_VERSION=3.1.73
RUN git checkout $SDK_VERSION

RUN ./emsdk install ${SDK_VERSION}
RUN ./emsdk activate ${SDK_VERSION}

RUN ls /usr/src/emsdk/node/

ENV NODE_VER=20.18.0

ENV PATH="/usr/src/emsdk:/usr/src/emsdk/upstream/emscripten:/usr/src/emsdk/upstream/bin:/usr/src/emsdk/node/${NODE_VER}_64bit/bin:${PATH}"
ENV EMSDK=/usr/src/emsdk
ENV EM_CONFIG=/usr/src/emsdk/.emscripten
ENV EM_CACHE=/usr/src/emsdk/upstream/emscripten/cache
ENV EMSDK_NODE=/usr/src/emsdk/node/${NODE_VER}_64bit/bin/node

RUN emcc -v
RUN node -v


ENV PROJECTDIR=/usr/src/octave-wasm
ENV THIRDPARTYDIR=$PROJECTDIR/third_party
ENV INSTALLDIR=$PROJECTDIR/target
ENV BINDIR=$INSTALLDIR/bin
ENV INCDIR=$INSTALLDIR/include
ENV LIBDIR=$INSTALLDIR/lib

WORKDIR $PROJECTDIR
RUN mkdir -p $BINDIR $INCDIR $LIBDIR


# Build f2c
COPY third_party/f2c-20160102 $THIRDPARTYDIR/f2c-20160102
RUN cd $THIRDPARTYDIR/f2c-20160102 && \
    make -j${JOBS:-4} all && \
    cp src/f2c $BINDIR && \
    # Verify f2c was built
    if [ ! -f "$BINDIR/f2c" ]; then \
        echo "ERROR: f2c was not built!" && exit 1; \
    fi && \
    echo "SUCCESS: f2c built and installed"


# Build libf2c
COPY third_party/libf2c2-20130926 $THIRDPARTYDIR/libf2c2-20130926
RUN cd $THIRDPARTYDIR/libf2c2-20130926 && \
    emmake make -j${JOBS:-4} all libf2c.a && \
    # Verify libf2c.a was created
    if [ ! -f "libf2c.a" ]; then \
        echo "ERROR: libf2c.a was not created!" && exit 1; \
    fi && \
    # Verify it's a valid archive
    emar t libf2c.a > /dev/null 2>&1 || (echo "ERROR: libf2c.a is not a valid archive!" && exit 1) && \
    echo "libf2c.a contains $(emar t libf2c.a | wc -l) object files" && \
    cp libf2c.a $LIBDIR && \
    cp f2c.h0 $INCDIR/f2c.h && \
    # Final verification
    if [ ! -f "$LIBDIR/libf2c.a" ] || [ ! -f "$INCDIR/f2c.h" ]; then \
        echo "ERROR: libf2c installation failed!" && exit 1; \
    fi && \
    echo "SUCCESS: libf2c built and installed"


# Build fort77
COPY third_party/fort77-1.15 $THIRDPARTYDIR/fort77-1.15
RUN cd $THIRDPARTYDIR/fort77-1.15 && \
    autoreconf -fi && \
    emmake make F2C=$BINDIR/f2c fort77 && \
    cp fort77 $BINDIR && \
    # Verify fort77 was built
    if [ ! -f "$BINDIR/fort77" ]; then \
        echo "ERROR: fort77 was not built!" && exit 1; \
    fi && \
    # Verify it's a script and references f2c correctly
    if ! grep -q "$BINDIR/f2c" "$BINDIR/fort77"; then \
        echo "ERROR: fort77 does not reference the correct f2c path!" && exit 1; \
    fi && \
    # Make it executable
    chmod +x $BINDIR/fort77 && \
    echo "SUCCESS: fort77 built and installed"


# Build LAPACK and BLAS
COPY third_party/lapack-3.4.2 $THIRDPARTYDIR/lapack-3.4.2
RUN cd $THIRDPARTYDIR/lapack-3.4.2 && \
    # Fix the make.inc to build static libraries instead of shared
    sed -i "s/TIMER *= *INT_ETIME/TIMER    = NONE/" make.inc && \
    # Create ignore list for problematic files
    echo "--- Creating ignore list for incompatible Fortran files ---" && \
    # Start with xerbla.f which we know uses len_trim
    echo "xerbla.f" > IGNORE_LIST.txt && \
    # Remove/rename files in ignore list before building
    for f in $(cat IGNORE_LIST.txt); do \
        echo "Ignoring $f due to f2c incompatibility" && \
        find . -name "$f" -exec mv {} {}.skip \; ; \
    done && \
    # Build BLAS - with problematic files removed
    echo "--- Building BLAS ---" && \
    (cd BLAS/SRC && emmake make F77=$BINDIR/fort77) && \
    # DIAGNOSTIC: Check what was built
    echo "=== BLAS build complete, checking results ===" && \
    echo "Object files created: $(find . -name "*.o" | wc -l)" && \
    # Create archive from whatever was successfully built
    (cd BLAS/SRC && find . -name "*.o" | xargs emar cr ../../librefblas.a) && \
    emranlib librefblas.a && \
    # Verify librefblas.a was created
    if [ ! -f "librefblas.a" ]; then \
        echo "ERROR: librefblas.a was not created!" && exit 1; \
    fi && \
    # DIAGNOSTIC: Check BLAS contents in detail
    echo "--- DIAGNOSTIC: BLAS library analysis ---" && \
    # Try different nm options
    echo "=== Using llvm-nm with different options ===" && \
    llvm-nm --print-armap librefblas.a | head -20 && \
    echo "=== Using regular nm if available ===" && \
    (nm librefblas.a 2>/dev/null | head -20 || echo "nm not available") && \
    echo "=== Using llvm-objdump ===" && \
    llvm-objdump -t librefblas.a | grep -E "(dgemm|daxpy|cgemm|zgemm)" | head -20 && \
    echo "=== Checking a specific .o file ===" && \
    llvm-nm BLAS/SRC/dgemm.o | head -10 && \
    echo "=== Real double precision BLAS (should have many) ===" && \
    llvm-nm librefblas.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T d" | head -20 && \
    echo "Total real double functions: $(llvm-nm librefblas.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T d" | wc -l)" && \
    echo "=== Complex BLAS functions (c/z prefix) ===" && \
    llvm-nm librefblas.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T [cz]" | head -20 && \
    echo "Total complex functions: $(llvm-nm librefblas.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T [cz]" | wc -l)" && \
    # If no complex functions, that's a problem
    if [ $(llvm-nm librefblas.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T [cz]" | wc -l) -eq 0 ]; then \
        echo "ERROR: No complex BLAS functions were built!" && \
        echo "Checking for complex source files:" && \
        ls -la BLAS/SRC/c*.f BLAS/SRC/z*.f | head -10 ; \
    fi && \
    # Check what we got
    echo "--- BLAS library contents ---" && \
    echo "librefblas.a contains $(emar t librefblas.a | wc -l) object files" && \
    for func in dgemm ddot daxpy dscal dcopy cgemm zgemm; do \
        if emar t librefblas.a | grep -q "${func}.o"; then \
            echo "Found ${func}.o in librefblas.a" ; \
        else \
            echo "WARNING: librefblas.a missing ${func}.o" ; \
        fi ; \
    done && \
    # Build LAPACK INSTALL
    echo "--- Building LAPACK INSTALL ---" && \
    (cd INSTALL && emmake make F77=$BINDIR/fort77) && \
    # Verify critical INSTALL files
    for func in dlamch slamch lsame; do \
        if [ ! -f "INSTALL/${func}.o" ]; then \
            echo "ERROR: ${func}.o not built in INSTALL!" && exit 1; \
        fi ; \
    done && \
    # Build LAPACK SRC
    echo "--- Building LAPACK SRC ---" && \
    (cd SRC && emmake make F77=$BINDIR/fort77) && \
    # DIAGNOSTIC: Check what actually got built
    echo "=== LAPACK SRC build results ===" && \
    echo "Total .o files in SRC: $(find SRC -name "*.o" | wc -l)" && \
    echo "Checking for complex LAPACK files:" && \
    find SRC -name "c*.o" -o -name "z*.o" | head -10 && \
    echo "Total complex .o files: $(find SRC -name "c*.o" -o -name "z*.o" | wc -l)" && \
    # Verify ilaenv was built in SRC
    if [ ! -f "SRC/ilaenv.o" ]; then \
        echo "ERROR: ilaenv.o not built in SRC!" && exit 1; \
    fi && \
    # Create archive from all successfully built objects
    find INSTALL SRC -name "*.o" | xargs emar cr libclapack.a && \
    emranlib libclapack.a && \
    # DIAGNOSTIC: Detailed LAPACK analysis
    echo "--- DIAGNOSTIC: LAPACK library analysis ---" && \
    echo "=== Real double precision LAPACK ===" && \
    llvm-nm libclapack.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T dge" | head -20 && \
    echo "Total dge* functions: $(llvm-nm libclapack.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T dge" | wc -l)" && \
    echo "=== Complex LAPACK functions ===" && \
    llvm-nm libclapack.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T [cz]ge" | head -20 && \
    echo "Total cge*/zge* functions: $(llvm-nm libclapack.a 2>/dev/null | grep " T " | grep -E "^[^ ]* T [cz]ge" | wc -l)" && \
    # Check for critical infrastructure functions
    echo "=== Checking critical infrastructure ===" && \
    for func in dlamch_ slamch_ ilaenv_ dgemm_ sgemm_ cgemm_ zgemm_; do \
        if llvm-nm libclapack.a librefblas.a 2>/dev/null | grep -q " T $func"; then \
            echo "FOUND: $func" ; \
        else \
            echo "MISSING: $func (CRITICAL!)" ; \
        fi ; \
    done && \
    # Verify libclapack.a contents
    echo "--- Verifying library contents ---" && \
    echo "librefblas.a key functions:" && \
    emar t librefblas.a | grep -E "(dgemm|ddot|daxpy|dscal|dcopy)" | sort && \
    echo "libclapack.a infrastructure functions:" && \
    emar t libclapack.a | grep -E "(dlamch|slamch|ilaenv|lsame)" | sort && \
    # DIAGNOSTIC: Check f2c library
    echo "--- DIAGNOSTIC: f2c library analysis ---" && \
    echo "=== f2c support functions ===" && \
    llvm-nm $LIBDIR/libf2c.a 2>/dev/null | grep " T " | grep -E "(c_abs|c_div|d_sign|pow_dd|s_cat|do_fio)" | head -20 && \
    echo "Total f2c functions: $(llvm-nm $LIBDIR/libf2c.a 2>/dev/null | grep " T " | wc -l)" && \
    # Check what files were skipped
    echo "=== Files skipped due to f2c issues ===" && \
    find . -name "*.f.skip" | wc -l && \
    # Create a simple C implementation of xerbla if needed
    echo "--- Creating xerbla.c as replacement ---" && \
    printf '%s\n' \
        '#include <stdio.h>' \
        '#include <stdlib.h>' \
        'void xerbla_(const char *srname, int *info) {' \
        '    fprintf(stderr, "LAPACK ERROR in %s: parameter %d is invalid\\n", srname, *info);' \
        '    abort();' \
        '}' > xerbla.c && \
    emcc -c xerbla.c -o xerbla.o && \
    emar r librefblas.a xerbla.o && \
    emranlib librefblas.a && \
    echo "Added C version of xerbla to librefblas.a" && \
    # Final summary
    echo "--- Library summary ---" && \
    echo "librefblas.a: $(emar t librefblas.a | wc -l) object files" && \
    echo "libclapack.a: $(emar t libclapack.a | wc -l) object files" && \
    cp librefblas.a $LIBDIR && \
    cp libclapack.a $LIBDIR && \
    echo "SUCCESS: LAPACK and BLAS built and installed"

# Build PCRE
COPY third_party/pcre-8.43 $THIRDPARTYDIR/pcre-8.43
RUN mkdir -p $THIRDPARTYDIR/pcre-8.43/build && \
    cd $THIRDPARTYDIR/pcre-8.43/build && \
    emcmake cmake .. \
    -DCMAKE_INSTALL_PREFIX=$INSTALLDIR \
    -DBUILD_SHARED_LIBS=OFF -DPCRE_BUILD_PCREGREP=OFF -DPCRE_BUILD_TESTS=OFF -DPCRE_SUPPORT_UTF=ON && \
    emmake make -j${JOBS:-4} && \
    # Verify libpcre.a was created
    if [ ! -f "libpcre.a" ]; then \
        echo "ERROR: libpcre.a was not created!" && exit 1; \
    fi && \
    emar t libpcre.a > /dev/null 2>&1 || (echo "ERROR: libpcre.a is not a valid archive!" && exit 1) && \
    echo "libpcre.a contains $(emar t libpcre.a | wc -l) object files" && \
    # Install using make install (preferred) or copy manually (I don't even know if this helps. why do we need pcre.h?)
    emmake make install || \
    (echo "WARNING: make install failed, copying files manually" && \
     cp libpcre.a $LIBDIR && \
     # Look for pcre.h in both source and build directories
     if [ -f "pcre.h" ]; then \
         cp pcre.h $INCDIR ; \
     elif [ -f "../pcre.h" ]; then \
         cp ../pcre.h $INCDIR ; \
     elif [ -f "../pcre.h.in" ]; then \
         echo "ERROR: pcre.h not generated - build may have failed!" && exit 1 ; \
     fi && \
     # Also copy other important headers
     for header in pcreposix.h pcrecpp.h; do \
         [ -f "$header" ] && cp $header $INCDIR ; \
         [ -f "../$header" ] && cp ../$header $INCDIR ; \
     done) && \
    # Final verification
    if [ ! -f "$LIBDIR/libpcre.a" ] || [ ! -f "$INCDIR/pcre.h" ]; then \
        echo "ERROR: PCRE installation failed!" && exit 1; \
    fi && \
    echo "SUCCESS: PCRE built and installed"


# Build SuiteSparse with comprehensive checks
COPY third_party/suitesparse-5.4.0 $THIRDPARTYDIR/suitesparse-5.4.0
RUN cd $THIRDPARTYDIR/suitesparse-5.4.0 && \
    sed -i -e "/( cd GraphBLAS /s/^/#/" -e "/( cd Mongoose /s/^/#/" -e "/( cd SPQR /s/^/#/" Makefile && \
    echo "--- Building SuiteSparse components ---" && \
    # SuiteSparse_config (must be first)
    echo "Building SuiteSparse_config..." && \
    (cd SuiteSparse_config && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for SuiteSparse_config!" && exit 1; \
        fi && \
        emar cr libsuitesparseconfig.a *.o && \
        emranlib libsuitesparseconfig.a && \
        if [ ! -f "libsuitesparseconfig.a" ] || [ $(emar t libsuitesparseconfig.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libsuitesparseconfig.a creation failed!" && exit 1; \
        fi && \
        cp libsuitesparseconfig.a $LIBDIR && \
        echo "SUCCESS: SuiteSparse_config built") && \
    # AMD
    echo "Building AMD..." && \
    (cd AMD && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib library && \
        cd Lib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for AMD!" && exit 1; \
        fi && \
        emar cr libamd.a *.o && \
        emranlib libamd.a && \
        if [ ! -f "libamd.a" ] || [ $(emar t libamd.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libamd.a creation failed!" && exit 1; \
        fi && \
        cp libamd.a $LIBDIR && \
        echo "SUCCESS: AMD built") && \
    # CAMD
    echo "Building CAMD..." && \
    (cd CAMD && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib library && \
        cd Lib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for CAMD!" && exit 1; \
        fi && \
        emar cr libcamd.a *.o && \
        emranlib libcamd.a && \
        if [ ! -f "libcamd.a" ] || [ $(emar t libcamd.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libcamd.a creation failed!" && exit 1; \
        fi && \
        cp libcamd.a $LIBDIR && \
        echo "SUCCESS: CAMD built") && \
    # COLAMD
    echo "Building COLAMD..." && \
    (cd COLAMD && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib library && \
        cd Lib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for COLAMD!" && exit 1; \
        fi && \
        emar cr libcolamd.a *.o && \
        emranlib libcolamd.a && \
        if [ ! -f "libcolamd.a" ] || [ $(emar t libcolamd.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libcolamd.a creation failed!" && exit 1; \
        fi && \
        cp libcolamd.a $LIBDIR && \
        echo "SUCCESS: COLAMD built") && \
    # CCOLAMD
    echo "Building CCOLAMD..." && \
    (cd CCOLAMD && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib library && \
        cd Lib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for CCOLAMD!" && exit 1; \
        fi && \
        emar cr libccolamd.a *.o && \
        emranlib libccolamd.a && \
        if [ ! -f "libccolamd.a" ] || [ $(emar t libccolamd.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libccolamd.a creation failed!" && exit 1; \
        fi && \
        cp libccolamd.a $LIBDIR && \
        echo "SUCCESS: CCOLAMD built") && \
    # CHOLMOD
    echo "Building CHOLMOD..." && \
    (cd CHOLMOD && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib \
            BLAS="$LIBDIR/librefblas.a" LAPACK="$LIBDIR/libclapack.a" library && \
        cd Lib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for CHOLMOD!" && exit 1; \
        fi && \
        emar cr libcholmod.a *.o && \
        emranlib libcholmod.a && \
        if [ ! -f "libcholmod.a" ] || [ $(emar t libcholmod.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libcholmod.a creation failed!" && exit 1; \
        fi && \
        cp libcholmod.a $LIBDIR && \
        echo "SUCCESS: CHOLMOD built") && \
    # UMFPACK
    echo "Building UMFPACK..." && \
    (cd UMFPACK && \
        emmake make -j${JOBS:-4} CC=emcc AR=emar RANLIB=emranlib \
            BLAS="$LIBDIR/librefblas.a" LAPACK="$LIBDIR/libclapack.a" library && \
        cd Lib && \
        if [ $(find . -name "*.o" | wc -l) -eq 0 ]; then \
            echo "ERROR: No object files created for UMFPACK!" && exit 1; \
        fi && \
        emar cr libumfpack.a *.o && \
        emranlib libumfpack.a && \
        if [ ! -f "libumfpack.a" ] || [ $(emar t libumfpack.a | wc -l) -eq 0 ]; then \
            echo "ERROR: libumfpack.a creation failed!" && exit 1; \
        fi && \
        cp libumfpack.a $LIBDIR && \
        echo "SUCCESS: UMFPACK built") && \
    # Copy all headers
    echo "Installing SuiteSparse headers..." && \
    cp AMD/Include/*.h $INCDIR && \
    cp CAMD/Include/*.h $INCDIR && \
    cp COLAMD/Include/*.h $INCDIR && \
    cp CCOLAMD/Include/*.h $INCDIR && \
    cp CHOLMOD/Include/*.h $INCDIR && \
    cp UMFPACK/Include/*.h $INCDIR && \
    cp SuiteSparse_config/*.h $INCDIR && \
    # Final comprehensive verification
    echo "--- Final SuiteSparse verification ---" && \
    MISSING_LIBS="" && \
    for lib in libamd.a libcamd.a libcolamd.a libccolamd.a libcholmod.a libumfpack.a libsuitesparseconfig.a; do \
        if [ ! -f "$LIBDIR/$lib" ]; then \
            MISSING_LIBS="$MISSING_LIBS $lib" ; \
        else \
            echo "$lib: $(ls -lh $LIBDIR/$lib | awk '{print $5}'), $(emar t $LIBDIR/$lib | wc -l) objects" ; \
        fi ; \
    done && \
    if [ -n "$MISSING_LIBS" ]; then \
        echo "ERROR: Missing libraries:$MISSING_LIBS" && exit 1; \
    fi && \
    echo "SUCCESS: All SuiteSparse components built and installed"


# Build Octave
ENV OCTAVE_VER=7.2.0
COPY third_party/octave-${OCTAVE_VER} $THIRDPARTYDIR/octave-${OCTAVE_VER}
WORKDIR $THIRDPARTYDIR/octave-${OCTAVE_VER}

# Pre-build verification
RUN echo "--- Pre-build verification ---" && \
    for lib in libf2c.a librefblas.a libclapack.a libpcre.a \
               libamd.a libcamd.a libcolamd.a libccolamd.a \
               libcholmod.a libumfpack.a libsuitesparseconfig.a; do \
        if [ ! -f "$LIBDIR/$lib" ]; then \
            echo "ERROR: Required library $lib not found!" && exit 1; \
        fi ; \
    done && \
    echo "All required libraries present"

RUN rm -f configure && autoreconf
# Manually set FORTRAN name-mangling to use lower-case and single underscore.
RUN sed -i -e 's/(name,NAME) name"/(name,NAME) name ## _"/g' configure

ENV BLAS_LIBS="$LIBDIR/librefblas.a $LIBDIR/libf2c.a -lm"
ENV LAPACK_LIBS="$LIBDIR/libclapack.a $LIBDIR/librefblas.a $LIBDIR/libf2c.a -lm"

RUN emconfigure ./configure \
    F77=$BINDIR/fort77 \
    CC=emcc \
    CXX=em++ \
    AR=emar \
    RANLIB=emranlib \
    CFLAGS="-I$INCDIR -O0" \
    CXXFLAGS="-std=c++11 -I$INCDIR -O0" \
    FFLAGS="-I$INCDIR -O0 -E" \
    FLIBS="" \
    BLAS_LIBS="$BLAS_LIBS" \
    LAPACK_LIBS="$LAPACK_LIBS" \
    LDFLAGS="-s ERROR_ON_UNDEFINED_SYMBOLS=0 -L$LIBDIR -O0" \
    EMCC_FORCE_STDLIBS=1 \
    --host=wasm32-local-emscripten \
    --prefix=$INSTALLDIR \
    --disable-shared --enable-static \
    --disable-threads --disable-openmp \
    --without-qt --disable-java --enable-fortran-calling-convention=f2c --disable-cross-tools \
    --disable-readline --disable-64 --disable-docs --without-curl --without-fftw3 \
    --disable-dlopen --disable-dl --disable-dynamic-linking \
    --without-fftw3f --without-hdf5 --without-opengl --without-qrupdate --without-framework-carbon --without-framework-opengl --without-x \
    --without-arpack --with-blas="$BLAS_LIBS" --with-lapack="$LAPACK_LIBS" \
    --without-sndfile --without-portaudio --without-freetype --without-fontconfig --without-fltk --without-qrupdate \
    --without-sundials_ida --without-sundials_nvecserial --without-sundials_sunlinsolklu --without-qhull_r \
    --with-pcre-includedir=$INCDIR --with-pcre-libdir=$LIBDIR \
    --with-amd-includedir=$INCDIR --with-amd-libdir=$LIBDIR \
    --with-camd-includedir=$INCDIR --with-camd-libdir=$LIBDIR \
    --with-colamd-includedir=$INCDIR --with-colamd-libdir=$LIBDIR \
    --with-ccolamd-includedir=$INCDIR --with-ccolamd-libdir=$LIBDIR \
    --with-cholmod-includedir=$INCDIR --with-cholmod-libdir=$LIBDIR \
    --with-umfpack-includedir=$INCDIR --with-umfpack-libdir=$LIBDIR \
    --without-cxsparse \
    --without-z --without-bz2 --without-magick --without-spqr --without-glpk --disable-rapidjson && \
    # Verify configure succeeded
    if [ ! -f "Makefile" ]; then \
        echo "ERROR: Octave configure failed!" && exit 1; \
    fi && \
    echo "SUCCESS: Octave configured"

RUN emmake make -j8 && \
    echo "--- Octave build completed, searching for all .a files ---" && \
    # Find all .a files in the build directory for diagnostic purposes
    echo "=== Finding all .a files in the build tree ===" && \
    find . -name "*.a" -type f | sort && \
    echo "=== End of .a file list ===" && \
    echo "SUCCESS: Octave built"

RUN emmake make install && \
    # Verify installation
    echo "--- Checking installed files ---" && \
    echo "=== Contents of $INSTALLDIR/lib/octave/${OCTAVE_VER}/ ===" && \
    ls -la "$INSTALLDIR/lib/octave/${OCTAVE_VER}/" || true && \
    # Verify the key files are installed
    if [ ! -f "$INSTALLDIR/lib/octave/${OCTAVE_VER}/liboctave.a" ]; then \
        echo "ERROR: liboctave.a was not installed!" && exit 1; \
    fi && \
    if [ ! -f "$INSTALLDIR/lib/octave/${OCTAVE_VER}/liboctinterp.a" ]; then \
        echo "ERROR: liboctinterp.a was not installed!" && exit 1; \
    fi && \
    if [ ! -d "$INSTALLDIR/include/octave-${OCTAVE_VER}" ]; then \
        echo "ERROR: Octave headers were not installed!" && exit 1; \
    fi && \
    echo "SUCCESS: Octave installed"

# Create final archive
# I think we need to add a info/index.json (for it to be a conda package?) and also archive it as .tar.bz2 instead
RUN tar -cjf /usr/src/octave-wasm/octave-build.tar.bz2 -C $INSTALLDIR . && \
    # Verify archive was created
    if [ ! -f "/usr/src/octave-wasm/octave-build.tar.bz2" ]; then \
        echo "ERROR: Final archive creation failed!" && exit 1; \
    fi && \
    echo "SUCCESS: Build complete! Archive size: $(ls -lh /usr/src/octave-wasm/octave-build.tar.bz2 | awk '{print $5}')"