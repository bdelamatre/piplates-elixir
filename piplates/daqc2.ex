defmodule Piplates.DAQC2 do

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use GenServer
  use Bitwise

  alias Circuits.I2C
  alias Circuits.SPI

   def start_link(arguments) do
    GenServer.start_link(__MODULE__, arguments, name: :piplates_daqc2)
  end

  @impl true
  def init(arguments) do

    pp_frame = 25 #25 #22
    pp_int = 22 #22 #15
    pp_ack = 23 #23 #16

    {:ok, pp_frame_gpio}  = Circuits.GPIO.open(pp_frame, :output)
    Circuits.GPIO.write(pp_frame_gpio, 0)

    Process.sleep(100)

    {:ok, pp_int_gpio} = Circuits.GPIO.open(pp_int, :input)
    Circuits.GPIO.set_pull_mode(pp_int_gpio, :pullup)

    {:ok, pp_ack_gpio} = Circuits.GPIO.open(pp_ack, :input)
    Circuits.GPIO.set_pull_mode(pp_ack_gpio, :pullup)

    {:ok, spi} = Circuits.SPI.open("spidev0.1",[speed_hz: 500000, delay_us: 5])

    Process.sleep(100)

    {:ok, [
      spi: spi,
      pp_frame_gpio: pp_frame_gpio,
      pp_int_gpio: pp_int_gpio,
      pp_ack_gpio: pp_ack_gpio,
    ]}

  end

  def get_base_address do
    32
  end

  def calculate_address(address) do
    get_base_address + address
  end

  def calibration_get_byte(pid, address, pointer) do

    ppcmd(pid, {address, 0xFD, 2, pointer, 1}) |> :binary.first

  end

  def calibration_put_byte(pid, address, data) do

    if data < 0 or data > 255 do
      raise "Calibration value is out of range. Must be in the range of 0 to 255"
    end

    ppcmd(pid, {address, 0xFD, 1, data, 0})

  end

  def calibration_erase_block(pid, address) do

    ppcmd(pid, {address, 0xFD, 0, 0, 0})

  end

  def get_calibration_values(pid, address) do

    #build enum of 8 calibrations
    calibration = Enum.map(0..7, fn i ->

      #get 8 values for each calibration
      values = Enum.map(0..5, fn j ->

          calibration_get_byte(pid, address, 6 * i + j)

      end)

      value0 = Enum.at(values,0)
      value1 = Enum.at(values,1)
      value2 = Enum.at(values,2)
      value3 = Enum.at(values,3)
      value4 = Enum.at(values,4)
      value5 = Enum.at(values,5)

      #calculate scale
      scale_sign = value0 &&& 0x80
      scale = 0.04 * ( (value0 &&& 0x7F) * 256 + value1 ) / 32767
      scale_final = if scale_sign != 0 do
          (scale * -1) + 1
      else
          scale + 1
      end

      #calculate offset
      offset_sign = value2 &&& 0x80
      offset = 0.2 * ( (value2 &&& 0x7F) * 256 + value3 ) / 32767
      offset_final = if offset_sign != 0 do
          offset * -1
      else
          offset
      end

      #calculate DAC
      dac_sign = value4 &&& 0x80
      dac = 0.04 * ( (value4 &&& 0x7F) * 256 + value5 ) / 32767
      dac_final = if dac_sign != 0 do
          (dac * -1) + 1
      else
          dac + 1
      end

      {scale_final, offset_final, dac_final}

    end)

    if :ets.whereis(:daqc2_registry) == :undefined do
      :ets.new(:daqc2_registry, [:named_table, :public])
    end

    :ets.insert(:daqc2_registry, {"calibration-0", calibration})

    calibration

  end

  def get_calibration_values_from_registry(pid, address) do

    lookup = :ets.lookup(:daqc2_registry, "calibration-#{address}")

    {name,calibration} = Enum.at(lookup,0)

    calibration

  end

  def read_spi(spi, max_count \\ 25, response \\ <<>>, count \\ 0) do

    #send dummy request to SPI just to get the next response
    {:ok, current_response} = Circuits.SPI.transfer(spi, <<0>>)

    #only request and return the number of bits requested + 1
    if count < max_count do
      read_spi(spi, max_count, response <> current_response, count + 1)
    else
      response <> current_response
    end

  end

  def wait_for_ack(spi, pp_frame_gpio, pp_ack_gpio, address, start_time \\ :os.system_time(:millisecond), loop \\ 1) do

    if Circuits.GPIO.read(pp_ack_gpio) === 0 do
      true
    else
      if (:os.system_time(:millisecond) - start_time) < 50 do
        wait_for_ack(spi, pp_frame_gpio, pp_ack_gpio, address, start_time, loop + 1)
      else
        false
      end
    end

  end

  def wait_for_frame_ready(spi, pp_frame_gpio, pp_ack_gpio, address, start_time \\ :os.system_time(:millisecond), loop \\ 0) do

    if Circuits.GPIO.read(pp_frame_gpio) === 0
        && Circuits.GPIO.read(pp_ack_gpio) === 1
      do
      true
    else
      if (:os.system_time(:millisecond) - start_time) < 500 do
        wait_for_frame_ready(spi, pp_frame_gpio, pp_ack_gpio, address, start_time, loop + 1)
      else
        false
      end
    end

  end

  def ppcmd(pid, {address, cmd, param1, param2, bytes}) do
    GenServer.call(pid, {:ppcmd, address, cmd, param1, param2, bytes})
  end

  def handle_call({:ppcmd, address, cmd, param1, param2, bytes}, _from, arguments) do

    #fetch state from init
    spi           = Keyword.fetch!(arguments, :spi)
    pp_frame_gpio = Keyword.fetch!(arguments, :pp_frame_gpio)
    pp_ack_gpio   = Keyword.fetch!(arguments, :pp_ack_gpio)

    frame_ready =  wait_for_frame_ready(spi, pp_frame_gpio, pp_ack_gpio, address)

    if frame_ready !== true do
      IO.puts("FRAME timeout for #{cmd} #{param1} #{param2}")
      raise("FRAME timeout for #{cmd} #{param1} #{param2}")
    else

      #get address
      real_address = calculate_address(address)

      #set the frame high
      Circuits.GPIO.write(pp_frame_gpio, 1)

      #send the frame
      Circuits.SPI.transfer(spi, <<real_address, cmd, param1, param2>>)

      #wait for ACK to CMD
      ack_cmd = wait_for_ack(spi, pp_frame_gpio, pp_ack_gpio, address)

      #wait for ACK to DATA if required
      ack_data = if ack_cmd === true and bytes > 0 do
        true
      else
        nil
      end

      #response
      response = if ack_data === true do
        read_spi(spi, bytes)
      else
        nil
      end

      #set the the frame low
      if ack_cmd === false or ack_data === false do
        Circuits.GPIO.write(pp_frame_gpio, 0)
        IO.puts("ACK timeout for #{cmd} #{param1} #{param2} (ack_cmd=#{ack_cmd} ack_data=#{ack_data})")
        raise("ACK timeout for #{cmd} #{param1} #{param2} (ack_cmd=#{ack_cmd} ack_data=#{ack_data})")
      else
        Circuits.GPIO.write(pp_frame_gpio, 0)
        {:reply, response, arguments}
      end

    end

  end

  def getADCall(pid, address) do

    response = ppcmd(pid,{address, 0x31, 0, 0, 16})

    response_chunked = response |> :binary.bin_to_list |> Enum.chunk_every(2)

    calibration = get_calibration_values_from_registry(pid, address)

    Enum.map(Enum.with_index(response_chunked), fn {chunk, index} ->

        {scale, offset, dac} = Enum.at(calibration, index)

        #combine chunks
        calc1 = 256 * Enum.at(chunk, 0) + Enum.at(chunk, 1)
        calc2 = (calc1 * 24.0 / 65536) - 12.0
        #calibrate value
        calc3 = calc2 * scale + offset

        calc3

    end)


  end

  def getADC(pid, address, channel) do

    response = ppcmd(pid, {address, 0x30, channel, 0, 2})

    response_chunked = response |> :binary.bin_to_list |> Enum.chunk_every(2) |> Enum.at(0)

    calibration = get_calibration_values_from_registry(pid, address)

    {scale, offset, dac} = Enum.at(calibration, channel)

    #combine chunks
    calc1 = 256 * Enum.at(response_chunked, 0) + Enum.at(response_chunked, 1)
    calc2 = (calc1 * 24.0 / 65536) - 12.0
    #calibrate value
    calc3 = calc2 * scale + offset

    calc3

  end

  #def setDOUTall(addr,byte):
  def setDOUTall(pid, address, byte) do
    ppcmd(pid, {address, 0x13, byte, 0, 0})
  end

  def setDOUTbit(pid, address, bit) do
    ppcmd(pid, {address, 0x10, bit, 0, 0})
  end

  def clrDOUTbit(pid, address, bit) do
    ppcmd(pid, {address, 0x11, bit, 0, 0})
  end

  def getDINbit(pid, address, bit) do

    value = ppcmd(pid, {address, 0x20, bit, 0, 1}) |> :binary.bin_to_list |> Enum.at(0)

    if value > 0 do
      1
    else
      0
    end

  end

  def reset(pid, address) do
    ppcmd(pid, {address, 0x0F, 0, 0, 0})
  end

end
