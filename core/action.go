package main

import (
	"encoding/json"
	"unsafe"

	"github.com/metacubex/mihomo/constant"
)

type Action struct {
	Id     string      `json:"id"`
	Method Method      `json:"method"`
	Data   interface{} `json:"data"`
}

type ActionResult struct {
	Id       string         `json:"id"`
	Method   Method         `json:"method"`
	Data     interface{}    `json:"data"`
	Code     int            `json:"code"`
	Callback unsafe.Pointer `json:"-"`
}

func (result ActionResult) Json() ([]byte, error) {
	data, err := json.Marshal(result)
	return data, err
}

func (result ActionResult) success(data interface{}) {
	result.Code = 0
	result.Data = data
	result.send()
}

func (result ActionResult) error(data interface{}) {
	result.Code = -1
	result.Data = data
	result.send()
}

func handleAction(action *Action, result ActionResult) {
	switch action.Method {
	case initClashMethod:
		paramsString, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		result.success(handleInitClash(paramsString))
		return
	case getIsInitMethod:
		result.success(handleGetIsInit())
		return
	case forceGcMethod:
		handleForceGc()
		result.success(true)
		return
	case shutdownMethod:
		result.success(handleShutdown())
		return
	case validateConfigMethod:
		s, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		data := []byte(s)
		result.success(handleValidateConfig(data))
		return
	case updateConfigMethod:
		s, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		data := []byte(s)
		result.success(handleUpdateConfig(data))
		return
	case setupConfigMethod:
		s, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		data := []byte(s)
		result.success(handleSetupConfig(data))
		return
	case getProxiesMethod:
		result.success(handleGetProxies())
		return
	case changeProxyMethod:
		data, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		handleChangeProxy(data, func(value string) {
			result.success(value)
		})
		return
	case getTrafficMethod:
		result.success(handleGetTraffic())
		return
	case getTotalTrafficMethod:
		result.success(handleGetTotalTraffic())
		return
	case resetTrafficMethod:
		handleResetTraffic()
		result.success(true)
		return
	case asyncTestDelayMethod:
		data, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		handleAsyncTestDelay(data, func(value string) {
			result.success(value)
		})
		return
	case getConnectionsMethod:
		result.success(handleGetConnections())
		return
	case closeConnectionsMethod:
		result.success(handleCloseConnections())
		return
	case resetConnectionsMethod:
		result.success(handleResetConnections())
		return
	case getConfigMethod:
		path, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		config, err := handleGetConfig(path)
		if err != nil {
			result.error(err)
			return
		}
		result.success(config)
		return
	case getCoreVersionMethod:
		result.success(constant.Version)
		return
	case closeConnectionMethod:
		id, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		result.success(handleCloseConnection(id))
		return
	case getExternalProvidersMethod:
		result.success(handleGetExternalProviders())
		return
	case getExternalProviderMethod:
		externalProviderName, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		result.success(handleGetExternalProvider(externalProviderName))
		return
	case updateGeoDataMethod:
		paramsString, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		var params = map[string]string{}
		err := json.Unmarshal([]byte(paramsString), &params)
		if err != nil {
			result.success(err.Error())
			return
		}
		geoType := params["geo-type"]
		geoName := params["geo-name"]
		handleUpdateGeoData(geoType, geoName, func(value string) {
			result.success(value)
		})
		return
	case updateExternalProviderMethod:
		providerName, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		handleUpdateExternalProvider(providerName, func(value string) {
			result.success(value)
		})
		return
	case sideLoadExternalProviderMethod:
		paramsString, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		var params = map[string]string{}
		err := json.Unmarshal([]byte(paramsString), &params)
		if err != nil {
			result.success(err.Error())
			return
		}
		providerName := params["providerName"]
		data := params["data"]
		handleSideLoadExternalProvider(providerName, []byte(data), func(value string) {
			result.success(value)
		})
		return
	case startLogMethod:
		handleStartLog()
		result.success(true)
		return
	case stopLogMethod:
		handleStopLog()
		result.success(true)
		return
	case startListenerMethod:
		result.success(handleStartListener())
		return
	case stopListenerMethod:
		result.success(handleStopListener())
		return
	case getCountryCodeMethod:
		ip, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		handleGetCountryCode(ip, func(value string) {
			result.success(value)
		})
		return
	case getMemoryMethod:
		handleGetMemory(func(value string) {
			result.success(value)
		})
		return
	case setStateMethod:
		data, ok := action.Data.(string)
		if !ok {
			result.error("invalid data type")
			return
		}
		handleSetState(data)
		result.success(true)
		return
	case healthCheckMethod:
		groupName, _ := action.Data.(string)
		handleHealthCheck(groupName, func(value string) {
			result.success(value)
		})
		return
	case crashMethod:
		result.success(true)
		handleCrash()
	default:
		if !nextHandle(action, result) {
			result.error("unknown method: " + string(action.Method))
		}
	}
}
