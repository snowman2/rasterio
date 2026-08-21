include "gdal.pxi"


cdef class DatasetBase:

    cdef GDALDatasetH _hds
    cdef readonly str name
    cdef readonly str mode
    cdef readonly dict options
    cdef readonly str _driver
    cdef readonly bint _count
    cdef readonly bint _width
    cdef readonly bint _height
    cdef readonly tuple _shape
    cdef readonly list _dtypes
    cdef readonly object _crs
    cdef readonly object _transform
    cdef readonly list _transform_gdal
    cdef readonly list _block_shapes
    cdef readonly list _nodatavals
    cdef readonly tuple _units
    cdef readonly tuple _descriptions
    cdef readonly tuple _scales
    cdef readonly tuple _offsets
    cdef readonly object _gcps
    cdef readonly object _rpcs
    cdef public object _env
    cdef GDALDatasetH handle(self) except NULL
    cdef GDALRasterBandH band(self, int bidx) except NULL


cdef const char *get_driver_name(GDALDriverH driver)

cdef void osr_set_traditional_axis_mapping_strategy(OGRSpatialReferenceH hSrs)
cdef GDALDatasetH open_dataset(object filename, unsigned int flags, object allowed_drivers, object open_options, bint sharing, object siblings) except NULL
