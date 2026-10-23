import Foundation

struct PIDDefinition {
    let pid: UInt8
    let short: String
    let detail: String
}

enum PIDTable {
    /// Mode 01 PID names. Kept compact: enough to identify what the car exposes.
    static let names: [UInt8: PIDDefinition] = {
        let raw: [(UInt8, String, String)] = [
            (0x01, "monitor_status", "Monitor status since DTCs cleared (MIL, DTC count, readiness)"),
            (0x03, "fuel_system_status", "Fuel system status"),
            (0x04, "engine_load", "Calculated engine load"),
            (0x05, "coolant_temp", "Engine coolant temperature"),
            (0x06, "stft_b1", "Short term fuel trim, bank 1"),
            (0x07, "ltft_b1", "Long term fuel trim, bank 1"),
            (0x08, "stft_b2", "Short term fuel trim, bank 2"),
            (0x09, "ltft_b2", "Long term fuel trim, bank 2"),
            (0x0A, "fuel_pressure", "Fuel pressure (gauge)"),
            (0x0B, "intake_map", "Intake manifold absolute pressure"),
            (0x0C, "rpm", "Engine speed"),
            (0x0D, "speed", "Vehicle speed"),
            (0x0E, "timing_advance", "Timing advance"),
            (0x0F, "intake_temp", "Intake air temperature"),
            (0x10, "maf", "Mass air flow rate"),
            (0x11, "throttle", "Throttle position"),
            (0x12, "secondary_air", "Commanded secondary air status"),
            (0x13, "o2_present", "Oxygen sensors present (2 banks)"),
            (0x1C, "obd_standard", "OBD standards this vehicle conforms to"),
            (0x1F, "run_time", "Run time since engine start"),
            (0x21, "distance_with_mil", "Distance travelled with MIL on"),
            (0x23, "rail_pressure_gauge", "Fuel rail gauge pressure (diesel)"),
            (0x2C, "commanded_egr", "Commanded EGR"),
            (0x2D, "egr_error", "EGR error"),
            (0x2E, "evap_purge", "Commanded evaporative purge"),
            (0x2F, "fuel_level", "Fuel tank level input"),
            (0x30, "warmups", "Warm-ups since codes cleared"),
            (0x31, "distance_since_clear", "Distance travelled since codes cleared"),
            (0x32, "evap_pressure", "Evaporative system vapour pressure"),
            (0x33, "barometric", "Absolute barometric pressure"),
            (0x3C, "cat_temp_b1s1", "Catalyst temperature, bank 1 sensor 1"),
            (0x3D, "cat_temp_b1s2", "Catalyst temperature, bank 1 sensor 2"),
            (0x3E, "cat_temp_b2s1", "Catalyst temperature, bank 2 sensor 1"),
            (0x3F, "cat_temp_b2s2", "Catalyst temperature, bank 2 sensor 2"),
            (0x41, "monitor_status_cycle", "Monitor status this drive cycle"),
            (0x42, "module_voltage", "Control module voltage"),
            (0x43, "absolute_load", "Absolute load value"),
            (0x44, "equivalence_ratio", "Commanded air-fuel equivalence ratio"),
            (0x45, "relative_throttle", "Relative throttle position"),
            (0x46, "ambient_temp", "Ambient air temperature"),
            (0x47, "throttle_b", "Absolute throttle position B"),
            (0x48, "throttle_c", "Absolute throttle position C"),
            (0x49, "accelerator_d", "Accelerator pedal position D"),
            (0x4A, "accelerator_e", "Accelerator pedal position E"),
            (0x4B, "accelerator_f", "Accelerator pedal position F"),
            (0x4C, "commanded_throttle", "Commanded throttle actuator"),
            (0x4D, "time_with_mil", "Time run with MIL on"),
            (0x4E, "time_since_clear", "Time since DTCs cleared"),
            (0x51, "fuel_type", "Fuel type"),
            (0x52, "ethanol_percent", "Ethanol fuel percentage"),
            (0x53, "evap_abs_pressure", "Absolute evap system vapour pressure"),
            (0x5C, "oil_temp", "Engine oil temperature"),
            (0x5D, "injection_timing", "Fuel injection timing"),
            (0x5E, "fuel_rate", "Engine fuel rate"),
            (0x5F, "emissions_standard", "Emission requirements this vehicle meets"),
            (0x61, "driver_demand_torque", "Driver's demand engine percent torque"),
            (0x62, "actual_torque", "Actual engine percent torque"),
            (0x63, "reference_torque", "Engine reference torque"),
            (0x64, "torque_data", "Engine percent torque data points"),
            (0x6A, "intake_air_control", "Commanded diesel intake air flow control"),
            (0x6B, "egr_temp", "Exhaust gas recirculation temperature"),
            (0x6D, "fuel_pressure_control", "Fuel pressure control system"),
            (0x6E, "injection_pressure", "Injection pressure control system"),
            (0x6F, "turbo_inlet_pressure", "Turbocharger compressor inlet pressure"),
            (0x70, "boost_control", "Boost pressure control"),
            (0x71, "vgt_control", "Variable geometry turbo control"),
            (0x73, "exhaust_pressure", "Exhaust pressure"),
            (0x74, "turbo_rpm", "Turbocharger speed"),
            (0x75, "turbo_temp", "Turbocharger temperature"),
            (0x76, "turbo_temp_2", "Turbocharger temperature (secondary)"),
            (0x77, "charge_cooler_temp", "Charge air cooler temperature"),
            (0x78, "egt_b1", "Exhaust gas temperature, bank 1"),
            (0x79, "egt_b2", "Exhaust gas temperature, bank 2"),
            (0x7A, "dpf_diff_pressure", "DPF 1 differential pressure"),
            (0x7B, "dpf_diff_pressure_2", "DPF 2 differential pressure"),
            (0x7C, "dpf_temp", "DPF 1 temperature"),
            (0x7D, "dpf_temp_2", "DPF 2 temperature"),
            (0x7F, "engine_run_time", "Engine run time"),
            (0x81, "aecd_run_time_1", "Engine run time for AECD #1"),
            (0x82, "aecd_run_time_2", "Engine run time for AECD #2"),
            (0x83, "nox_sensor", "NOx sensor"),
            (0x84, "manifold_temp", "Manifold surface temperature"),
            (0x85, "nox_reagent", "NOx reagent system"),
            (0x86, "pm_sensor", "Particulate matter sensor"),
            (0x8B, "aftertreatment_status", "Diesel aftertreatment status"),
            (0x8D, "throttle_g", "Throttle position G"),
            (0x8E, "friction_torque", "Engine friction percent torque"),
            (0x8F, "pm_sensor_b1", "Particulate matter sensor bank 1")
        ]
        var dict: [UInt8: PIDDefinition] = [:]
        for (pid, short, detail) in raw {
            dict[pid] = PIDDefinition(pid: pid, short: short, detail: detail)
        }
        return dict
    }()

    static func name(_ pid: UInt8) -> String {
        names[pid]?.short ?? String(format: "pid_%02X", pid)
    }

    static func detail(_ pid: UInt8) -> String {
        names[pid]?.detail ?? "Unknown or manufacturer-specific PID"
    }

    /// Decodes the well-understood PIDs only. Anything else is reported as raw hex,
    /// because guessing a scaling factor produces confident nonsense.
    static func decode(pid: UInt8, data: [UInt8]) -> (value: Double, unit: String)? {
        switch pid {
        case 0x04:
            guard let a = data.first else { return nil }
            return (Double(a) * 100.0 / 255.0, "%")
        case 0x05:
            guard let a = data.first else { return nil }
            return (Double(a) - 40.0, "degC")
        case 0x0B:
            guard let a = data.first else { return nil }
            return (Double(a), "kPa")
        case 0x0C:
            guard data.count >= 2 else { return nil }
            return ((Double(data[0]) * 256.0 + Double(data[1])) / 4.0, "rpm")
        case 0x0D:
            guard let a = data.first else { return nil }
            return (Double(a), "km/h")
        case 0x0F:
            guard let a = data.first else { return nil }
            return (Double(a) - 40.0, "degC")
        case 0x10:
            guard data.count >= 2 else { return nil }
            return ((Double(data[0]) * 256.0 + Double(data[1])) / 100.0, "g/s")
        case 0x11:
            guard let a = data.first else { return nil }
            return (Double(a) * 100.0 / 255.0, "%")
        case 0x23:
            guard data.count >= 2 else { return nil }
            return ((Double(data[0]) * 256.0 + Double(data[1])) * 10.0, "kPa")
        case 0x2F:
            guard let a = data.first else { return nil }
            return (Double(a) * 100.0 / 255.0, "%")
        case 0x33:
            guard let a = data.first else { return nil }
            return (Double(a), "kPa")
        case 0x42:
            guard data.count >= 2 else { return nil }
            return ((Double(data[0]) * 256.0 + Double(data[1])) / 1000.0, "V")
        case 0x45:
            guard let a = data.first else { return nil }
            return (Double(a) * 100.0 / 255.0, "%")
        case 0x46:
            guard let a = data.first else { return nil }
            return (Double(a) - 40.0, "degC")
        case 0x5C:
            guard let a = data.first else { return nil }
            return (Double(a) - 40.0, "degC")
        default:
            return nil
        }
    }
}
